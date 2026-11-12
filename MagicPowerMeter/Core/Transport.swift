import Foundation

protocol SensorTransport: AnyObject, Sendable {
	func discover(_ completion: @escaping @Sendable (Result<[String], SerialFailure>) -> Void)
	func connect(settings: SerialSettings, demo: Bool,
				 callback: @escaping @Sendable (TransportEvent) -> Void)
	func disconnect()
}

enum SerialParity: RawRepresentable, CaseIterable, Sendable {
	case none, even, odd

	var rawValue: String {
		switch self {
		case .none: return Strings.Connection.parityNone
		case .even: return Strings.Connection.parityEven
		case .odd: return Strings.Connection.parityOdd
		}
	}

	init?(rawValue: String) {
		switch rawValue {
		case Strings.Connection.parityNone: self = .none
		case Strings.Connection.parityEven: self = .even
		case Strings.Connection.parityOdd: self = .odd
		default: return nil
		}
	}
}

struct SerialSettings: Equatable, Sendable {
	var port = ""
	var baud = 9600
	var dataBits = 8
	var parity: SerialParity = .none
	var stopBits = 1
	var ending: LineEnding = .lf
	var timeout: TimeInterval = 8

	var summary: String {
		Strings.Connection.summary(baud: baud, dataBits: dataBits,
								  parity: parity == .none ? "N" : parity == .even ? "E" : "O", stopBits: stopBits)
	}
}

enum TransportEvent: Sendable {
	case preparing(String)
	case ready(String)
	case batch(SensorBatch)
	case failure(String)
}

struct SerialFailure: LocalizedError, Sendable {
	let message: String
	var errorDescription: String? { message }
}
