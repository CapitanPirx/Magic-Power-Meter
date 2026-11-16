import Foundation

enum MeasurementMode: CaseIterable, Sendable {
	case single, comparison, sprint

	var title: String {
		switch self {
		case .single: return Strings.Common.singleMeasurement
		case .comparison: return Strings.Common.comparisonMeasurement
		case .sprint: return Strings.Common.sprintMeasurement
		}
	}

	var defaultConditions: [Condition] {
		switch self {
		case .single: return [Condition(name: Strings.Common.singleMeasurement, iterations: 1)]
		case .comparison:
			return [Condition(name: Strings.Common.base, iterations: 3),
					Condition(name: Strings.Common.condition(1), iterations: 3)]
		case .sprint: return Strings.Measurement.sprintScenarios.map { Condition(name: $0, iterations: 3) }
		}
	}
}

enum MeasurementSource: RawRepresentable, Sendable {
	case serial, demo

	var rawValue: String {
		switch self {
		case .serial: return Strings.Measurement.sensorSource
		case .demo: return Strings.Measurement.demoSource
		}
	}

	init?(rawValue: String) {
		switch rawValue {
		case Strings.Measurement.sensorSource: self = .serial
		case Strings.Measurement.demoSource: self = .demo
		default: return nil
		}
	}
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
	fileprivate(set) var includedInCalculations = false
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
	let mode: MeasurementMode
	private(set) var name: String
	let conditions: [Condition]
	let duration: TimeInterval
	let timeout: TimeInterval
	let source: MeasurementSource
	let connectionDescription: String
	private(set) var attempts: [MeasurementAttempt] = []
	private(set) var activeIndex: Int?
	private(set) var finalized = false
	private var finalizeAfterAttempt = false

	init(mode: MeasurementMode, conditions: [Condition], duration: TimeInterval, timeout: TimeInterval,
		 source: MeasurementSource, connectionDescription: String, createdAt: Date = Date()) {
		self.mode = mode
		self.name = mode.title
		self.conditions = conditions
		self.duration = duration
		self.timeout = timeout
		self.source = source
		self.connectionDescription = connectionDescription
		self.createdAt = createdAt
	}

	var active: MeasurementAttempt? { activeIndex.map { attempts[$0] } }
	var totalIterations: Int { conditions.reduce(0) { $0 + $1.iterations } }
	var includedAttempts: LazyFilterSequence<[MeasurementAttempt]> { attempts.lazy.filter(\.includedInCalculations) }
	var completedIterations: Int { includedAttempts.count }
	var incomplete: Bool { completedIterations != totalIterations }

	func completed(_ key: IterationKey) -> MeasurementAttempt? {
		includedAttempts.first { $0.key == key }
	}

	var iterationKeys: [IterationKey] {
		conditions.flatMap { condition in
			(0..<max(0, condition.iterations)).map { IterationKey(conditionID: condition.id, number: $0 + 1) }
		}
	}

	func nextStartKey(selected: IterationKey?) -> IterationKey? {
		guard !finalized, activeIndex == nil else { return nil }
		if let selected, iterationKeys.contains(selected), completed(selected) == nil { return selected }
		return iterationKeys.first { completed($0) == nil }
	}

	mutating func rename(_ name: String) throws {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw MeasurementError.invalidName }
		self.name = trimmed
	}

	func latest(_ key: IterationKey) -> MeasurementAttempt? {
		attempts.last { $0.key == key }
	}

	mutating func start(_ key: IterationKey, uptime: TimeInterval, date: Date,
						connectionDescription: String? = nil) throws {
		try begin(key, retry: false, uptime: uptime, date: date, connectionDescription: connectionDescription)
	}

	mutating func retry(_ key: IterationKey, uptime: TimeInterval, date: Date,
						connectionDescription: String? = nil) throws {
		guard mode != .single, latest(key) != nil else { throw MeasurementError.invalidIteration }
		try begin(key, retry: true, uptime: uptime, date: date, connectionDescription: connectionDescription)
	}

	private mutating func begin(_ key: IterationKey, retry: Bool, uptime: TimeInterval, date: Date,
								connectionDescription: String?) throws {
		guard (retry || !finalized), activeIndex == nil else { throw MeasurementError.invalidState }
		guard duration.isFinite, duration > 0, timeout.isFinite, timeout > 0,
			  let condition = conditions.first(where: { $0.id == key.conditionID }),
			  condition.iterations > 0, (1...condition.iterations).contains(key.number),
			  retry || completed(key) == nil else {
			throw MeasurementError.invalidIteration
		}
		let number = attempts.lazy.filter { $0.key == key }.count + 1
		finalizeAfterAttempt = finalized
		finalized = false
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
				attempts[index].warnings.append(Strings.Measurement.header(at: elapsed))
			case .invalid(let reason):
				attempts[index].warnings.append(Strings.Measurement.invalidLine(at: elapsed, reason: reason))
			case .reading(let reading):
				if let previous = attempts[index].samples.last {
					if reading.count <= previous.reading.count {
						attempts[index].warnings.append(Strings.Measurement.counterReset)
					} else if reading.count - previous.reading.count > 1 {
						attempts[index].warnings.append(Strings.Measurement.missingLines(reading.count - previous.reading.count - 1))
					}
					if elapsed - previous.elapsed > 2.5 {
						attempts[index].warnings.append(Strings.Measurement.gap(elapsed - previous.elapsed))
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
				   complete: covered, reason: covered ? Strings.Measurement.timerFinished : Strings.Measurement.insufficientCoverage)
		} else {
			let last = attempts[index].samples.last?.elapsed ?? 0
			if elapsed - last >= timeout {
				finish(uptime: uptime, date: date, complete: false, reason: Strings.Measurement.readingTimeout)
			}
		}
	}

	mutating func stop(uptime: TimeInterval, date: Date,
					   reason: String = Strings.Measurement.manuallyStopped) {
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
		if attempts[index].complete {
			let key = attempts[index].key
			for previous in attempts.indices where attempts[previous].key == key {
				attempts[previous].includedInCalculations = previous == index
			}
		}
		attempts[index].stopReason = reason
		activeIndex = nil
		finalized = finalizeAfterAttempt
		finalizeAfterAttempt = false
	}

	mutating func finalize(uptime: TimeInterval, date: Date) {
		stop(uptime: uptime, date: date, reason: Strings.Measurement.finalizedEarly)
		finalized = true
	}

	func mean(conditionID: UUID) -> Double? {
		let values = includedAttempts.filter { $0.key.conditionID == conditionID }.compactMap(\.mean)
		return Numeric.mean(values)
	}

}

enum MeasurementError: LocalizedError {
	case invalidState, invalidIteration, invalidName
	var errorDescription: String? {
		switch self {
		case .invalidState: return Strings.Measurement.invalidState
		case .invalidIteration: return Strings.Measurement.invalidIteration
		case .invalidName: return Strings.Measurement.invalidName
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
		guard let value, value.isFinite else { return Strings.Common.unavailable }
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
