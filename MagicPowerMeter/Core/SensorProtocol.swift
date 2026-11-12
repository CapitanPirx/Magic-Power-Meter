import Foundation

struct SensorReading: Equatable, Sendable {
	let count: UInt64
	let voltage: Double
	let current: Double
	let power: Double
}

enum SensorLine: Equatable, Sendable {
	case reading(SensorReading)
	case header
	case invalid(String)
}

enum SensorParser {
	static func parse(_ data: Data) -> SensorLine {
		guard let text = String(data: data, encoding: .utf8) else {
			return .invalid(Strings.Measurement.invalidUTF8)
		}
		let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
			.split(separator: ";", omittingEmptySubsequences: false)
			.map { $0.trimmingCharacters(in: .whitespaces) }
		if fields.map({ $0.lowercased() }) == ["count", "voltage_v", "current_ma", "power_w"] {
			return .header
		}
		guard fields.count == 4, let count = UInt64(fields[0]) else {
			return .invalid(Strings.Measurement.expectedReading)
		}
		let numbers = fields.dropFirst().compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
		guard numbers.count == 3, numbers.allSatisfy(\.isFinite),
			  numbers[0] >= 0, numbers[1] >= 0, numbers[2] >= 0 else {
			return .invalid(Strings.Measurement.invalidReading)
		}
		return .reading(SensorReading(count: count, voltage: numbers[0], current: numbers[1], power: numbers[2]))
	}
}

enum LineEnding: RawRepresentable, CaseIterable, Sendable {
	case lf, crlf, cr

	var rawValue: String {
		switch self {
		case .lf: return Strings.Connection.lineLF
		case .crlf: return Strings.Connection.lineCRLF
		case .cr: return Strings.Connection.lineCR
		}
	}

	init?(rawValue: String) {
		switch rawValue {
		case Strings.Connection.lineLF: self = .lf
		case Strings.Connection.lineCRLF: self = .crlf
		case Strings.Connection.lineCR: self = .cr
		default: return nil
		}
	}

	var delimiter: [UInt8] {
		switch self {
		case .lf: return [10]
		case .crlf: return [13, 10]
		case .cr: return [13]
		}
	}
}

struct TimedLine: Sendable {
	let value: SensorLine
	let beganAt: TimeInterval
}

struct SensorBatch: Sendable {
	let raw: Data
	let lines: [TimedLine]
	let uptime: TimeInterval
	let date: Date
}

struct StreamDecoder {
	var ending: LineEnding = .lf
	private var pending = Data()
	private var beganAt: TimeInterval?
	private var discarding = false
	private var previousByte: UInt8?

	mutating func receive(_ data: Data, uptime: TimeInterval, date: Date) -> SensorBatch {
		var lines: [TimedLine] = []
		for byte in data {
			if beganAt == nil { beganAt = uptime }
			if !discarding { pending.append(byte) }
			let ended: Bool
			switch ending {
			case .lf: ended = byte == 10
			case .cr: ended = byte == 13
			case .crlf: ended = byte == 10 && previousByte == 13
			}
			previousByte = byte
			if ended {
				if !discarding {
					lines.append(TimedLine(value: SensorParser.parse(pending), beganAt: beganAt ?? uptime))
				}
				pending.removeAll(keepingCapacity: true)
				beganAt = nil
				discarding = false
			} else if pending.count > 4096 {
				lines.append(TimedLine(value: .invalid(Strings.Measurement.oversizedLine), beganAt: beganAt ?? uptime))
				pending.removeAll(keepingCapacity: true)
				discarding = true
			}
		}
		return SensorBatch(raw: data, lines: lines, uptime: uptime, date: date)
	}
}
