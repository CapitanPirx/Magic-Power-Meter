import Foundation

enum MeasurementSource: String, Sendable {
	case serial = "ДАТЧИК"
	case demo = "ДЕМО — СИНТЕТИЧЕСКИЕ ДАННЫЕ"
}

struct Condition: Identifiable, Equatable, Sendable {
	let id: UUID
	var name: String
	var iterations: Int

	init(id: UUID = UUID(), name: String, iterations: Int) {
		self.id = id
		self.name = name
		self.iterations = iterations
	}
}

struct IterationKey: Hashable, Sendable {
	let conditionID: UUID
	let number: Int
}

struct PowerSample: Identifiable, Sendable {
	let id = UUID()
	let elapsed: TimeInterval
	let date: Date
	let reading: SensorReading
}

struct RawChunk: Sendable {
	let date: Date
	let elapsed: TimeInterval
	let data: Data
}

struct MeasurementAttempt: Identifiable, Sendable {
	let id = UUID()
	let key: IterationKey
	let number: Int
	let startedAt: Date
	let startUptime: TimeInterval
	var connectionDescription: String = ""
	var endedAt: Date?
	var elapsed: TimeInterval = 0
	var stoppedAfter: TimeInterval?
	var samples: [PowerSample] = []
	var chunks: [RawChunk] = []
	var warnings: [String] = []
	var complete = false
	var stopReason: String?

	var mean: Double? {
		Numeric.mean(samples.lazy.map { $0.reading.power })
	}

	var frequency: Double? {
		guard let first = samples.first, let last = samples.last, last.elapsed > first.elapsed else { return nil }
		return Double(samples.count - 1) / (last.elapsed - first.elapsed)
	}

	var missingReadings: Double {
		zip(samples, samples.dropFirst()).reduce(0) { total, pair in
			let previous = pair.0.reading.count
			let next = pair.1.reading.count
			return total + (next > previous ? Double(next - previous - 1) : 0)
		}
	}
}

struct MeasurementSession: Sendable {
	let id = UUID()
	let createdAt: Date
	let conditions: [Condition]
	let duration: TimeInterval
	let timeout: TimeInterval
	let source: MeasurementSource
	let connectionDescription: String
	private(set) var attempts: [MeasurementAttempt] = []
	private(set) var activeIndex: Int?
	private(set) var finalized = false

	init(conditions: [Condition], duration: TimeInterval, timeout: TimeInterval,
		 source: MeasurementSource, connectionDescription: String, createdAt: Date = Date()) {
		self.conditions = conditions
		self.duration = duration
		self.timeout = timeout
		self.source = source
		self.connectionDescription = connectionDescription
		self.createdAt = createdAt
	}

	var active: MeasurementAttempt? { activeIndex.map { attempts[$0] } }
	var totalIterations: Int { conditions.reduce(0) { $0 + $1.iterations } }
	var completedIterations: Int { attempts.lazy.filter(\.complete).count }
	var incomplete: Bool { completedIterations != totalIterations }

	func completed(_ key: IterationKey) -> MeasurementAttempt? {
		attempts.first { $0.key == key && $0.complete }
	}

	func latest(_ key: IterationKey) -> MeasurementAttempt? {
		attempts.last { $0.key == key }
	}

	mutating func start(_ key: IterationKey, uptime: TimeInterval, date: Date,
						connectionDescription: String? = nil) throws {
		guard !finalized, activeIndex == nil else { throw MeasurementError.invalidState }
		guard duration.isFinite, duration > 0, timeout.isFinite, timeout > 0,
			  let condition = conditions.first(where: { $0.id == key.conditionID }),
			  condition.iterations > 0, (1...condition.iterations).contains(key.number), completed(key) == nil else {
			throw MeasurementError.invalidIteration
		}
		let number = attempts.lazy.filter { $0.key == key }.count + 1
		attempts.append(MeasurementAttempt(key: key, number: number, startedAt: date, startUptime: uptime,
										   connectionDescription: connectionDescription ?? self.connectionDescription))
		activeIndex = attempts.count - 1
	}

	mutating func receive(_ batch: SensorBatch) {
		guard let index = activeIndex else { return }
		let elapsed = batch.uptime - attempts[index].startUptime
		guard elapsed >= 0 else { return }
		guard elapsed < duration else {
			tick(uptime: batch.uptime, date: batch.date)
			return
		}
		attempts[index].chunks.append(RawChunk(date: batch.date, elapsed: elapsed, data: batch.raw))
		attempts[index].elapsed = elapsed
		for line in batch.lines where line.beganAt >= attempts[index].startUptime {
			switch line.value {
			case .header:
				attempts[index].warnings.append("Заголовок / возможный reset датчика на \(Numeric.text(elapsed)) с")
			case .invalid(let reason):
				attempts[index].warnings.append("\(Numeric.text(elapsed)) с: \(reason)")
			case .reading(let reading):
				if let previous = attempts[index].samples.last {
					if reading.count <= previous.reading.count {
						attempts[index].warnings.append("Счётчик датчика сброшен или повторён")
					} else if reading.count - previous.reading.count > 1 {
						attempts[index].warnings.append("Пропущены строки: \(reading.count - previous.reading.count - 1)")
					}
					if elapsed - previous.elapsed > 2.5 {
						attempts[index].warnings.append("Разрыв данных: \(Numeric.text(elapsed - previous.elapsed)) с")
					}
				}
				attempts[index].samples.append(PowerSample(elapsed: elapsed, date: batch.date, reading: reading))
			}
		}
	}

	mutating func tick(uptime: TimeInterval, date: Date) {
		guard let index = activeIndex else { return }
		let elapsed = max(0, uptime - attempts[index].startUptime)
		attempts[index].elapsed = min(elapsed, duration)
		if elapsed >= duration {
			let samples = attempts[index].samples
			let tolerance = min(timeout, max(2.5, duration / 10))
			let gaps = zip(samples, samples.dropFirst()).map { $1.elapsed - $0.elapsed }
			let covered = samples.first.map { $0.elapsed <= tolerance } == true
				&& samples.last.map { duration - $0.elapsed <= tolerance } == true
				&& !gaps.contains { $0 > timeout }
			finish(uptime: uptime, date: date,
				   complete: covered, reason: covered ? "Таймер завершён" : "Недостаточное покрытие данными")
		} else {
			let last = attempts[index].samples.last?.elapsed ?? 0
			if elapsed - last >= timeout {
				finish(uptime: uptime, date: date, complete: false, reason: "Таймаут показаний")
			}
		}
	}

	mutating func stop(uptime: TimeInterval, date: Date,
					   reason: String = "Остановлено вручную — исключено из расчётов") {
		guard let index = activeIndex else { return }
		if uptime - attempts[index].startUptime >= duration {
			tick(uptime: uptime, date: date)
		} else {
			finish(uptime: uptime, date: date, complete: false, reason: reason)
		}
	}

	private mutating func finish(uptime: TimeInterval, date: Date, complete: Bool, reason: String) {
		guard let index = activeIndex else { return }
		attempts[index].elapsed = min(duration, max(0, uptime - attempts[index].startUptime))
		attempts[index].stoppedAfter = max(0, uptime - attempts[index].startUptime)
		attempts[index].endedAt = date
		attempts[index].complete = complete && !attempts[index].samples.isEmpty
		attempts[index].stopReason = reason
		activeIndex = nil
	}

	mutating func finalize(uptime: TimeInterval, date: Date) {
		stop(uptime: uptime, date: date, reason: "Сессия завершена досрочно — исключено из расчётов")
		finalized = true
	}

	func mean(conditionID: UUID) -> Double? {
		let values = attempts.lazy.filter { $0.complete && $0.key.conditionID == conditionID }.compactMap(\.mean)
		return Numeric.mean(values)
	}

}

enum MeasurementError: LocalizedError {
	case invalidState, invalidIteration
	var errorDescription: String? {
		switch self {
		case .invalidState: return "Сначала остановите текущую итерацию или создайте новую сессию."
		case .invalidIteration: return "Итерация недоступна или уже завершена."
		}
	}
}

enum Numeric {
	static func mean<Values: Sequence>(_ values: Values) -> Double? where Values.Element == Double {
		var mean = 0.0
		var count = 0
		for value in values {
			count += 1
			mean += (value - mean) / Double(count)
		}
		return count == 0 ? nil : mean
	}

	static func text(_ value: Double?) -> String {
		guard let value, value.isFinite else { return "—" }
		return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
			.replacingOccurrences(of: ".", with: ",")
	}

	static func delta(_ value: Double?, base: Double?) -> Double? {
		guard let value, let base, value.isFinite, base.isFinite else { return nil }
		return value - base
	}

	static func percent(_ value: Double?, base: Double?) -> Double? {
		guard let base, base != 0, let delta = delta(value, base: base) else { return nil }
		let percent = delta / base * 100
		return percent.isFinite ? percent : nil
	}
}
