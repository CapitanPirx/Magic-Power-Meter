import Foundation
import Darwin
import IOKit
import IOKit.serial

final class SerialTransport: SensorTransport, @unchecked Sendable {
	private let queue = DispatchQueue(label: "dev.magicpowermeter.serial", qos: .userInitiated)
	private let portsProvider: @Sendable () throws -> [String]
	private var timer: DispatchSourceTimer?
	private var fd: Int32 = -1
	private var original: termios?
	private var decoder = StreamDecoder()
	private var settings = SerialSettings()
	private var callback: (@Sendable (TransportEvent) -> Void)?
	private var candidates: [String] = []
	private var candidateIndex = 0
	private var candidateErrors: [String] = []
	private var path = ""
	private var validated = false
	private var lastValid: TimeInterval = 0
	private var isDemo = false
	private var demoCount: UInt64 = 0
	private var nextDemo: TimeInterval = 0

	init(portsProvider: @escaping @Sendable () throws -> [String] = { try SerialTransport.availablePorts() }) {
		self.portsProvider = portsProvider
	}

	deinit { close() }

	static func availablePorts() throws -> [String] {
		var iterator: io_iterator_t = 0
		let matching = IOServiceMatching(kIOSerialBSDServiceValue)
		let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
		guard status == KERN_SUCCESS else {
			throw SerialFailure(message: Strings.Connection.discoveryFailed(status))
		}
		defer { IOObjectRelease(iterator) }
		var ports: [String] = []
		var service = IOIteratorNext(iterator)
		while service != 0 {
			if let value = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString,
														  kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
				ports.append(value)
			}
			IOObjectRelease(service)
			service = IOIteratorNext(iterator)
		}
		return ports.sorted()
	}

	func discover(_ completion: @escaping @Sendable (Result<[String], SerialFailure>) -> Void) {
		queue.async {
			do { completion(.success(try self.portsProvider())) }
			catch { completion(.failure(SerialFailure(message: error.localizedDescription))) }
		}
	}

	func connect(settings: SerialSettings, demo: Bool,
				 callback: @escaping @Sendable (TransportEvent) -> Void) {
		queue.async { [self] in
			self.close()
			self.settings = settings
			self.callback = callback
			self.isDemo = demo
			self.decoder = StreamDecoder(ending: settings.ending)
			if demo {
				self.path = Strings.Connection.demoName
				self.validated = true
				self.demoCount = 0
				self.nextDemo = MonotonicTime.now
				callback(.ready(self.path))
			} else {
				do {
					self.candidates = settings.port.isEmpty ? try self.portsProvider() : [settings.port]
				} catch {
					self.fail(error.localizedDescription)
					return
				}
				self.candidateIndex = 0
				self.candidateErrors = []
				guard self.openNext() else { return }
			}
			let timer = DispatchSource.makeTimerSource(queue: self.queue)
			timer.schedule(deadline: .now(), repeating: .milliseconds(100))
			timer.setEventHandler { [weak transport = self] in transport?.poll() }
			self.timer = timer
			timer.resume()
		}
	}

	func disconnect() {
		queue.async {
			self.close()
			self.callback = nil
		}
	}

	private func closePort() {
		if fd >= 0 {
			if var original { _ = tcsetattr(fd, TCSANOW, &original) }
			_ = Darwin.close(fd)
			fd = -1
		}
		original = nil
	}

	private func close() {
		timer?.setEventHandler {}
		timer?.cancel()
		timer = nil
		closePort()
	}

	private func fail(_ message: String) {
		close()
		callback?(.failure(message))
	}

	private func openNext() -> Bool {
		closePort()
		validated = false
		while candidateIndex < candidates.count {
			path = candidates[candidateIndex]
			candidateIndex += 1
			callback?(.preparing(Strings.Connection.preparing(path)))
			fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
			guard fd >= 0 else {
				candidateErrors.append(Strings.Connection.portError(path: path, reason: String(cString: strerror(errno))))
				continue
			}
			if ioctl(fd, TIOCEXCL) < 0 {
				candidateErrors.append(Strings.Connection.portError(path: path, reason: Strings.Connection.exclusiveAccessFailed(String(cString: strerror(errno)))))
				closePort()
				continue
			}
			var attributes = termios()
			guard tcgetattr(fd, &attributes) == 0 else {
				candidateErrors.append(Strings.Connection.portError(path: path, reason: Strings.Connection.attributesFailed(String(cString: strerror(errno)))))
				closePort()
				continue
			}
			original = attributes
			cfmakeraw(&attributes)
			attributes.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
			attributes.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTS_IFLOW | CCTS_OFLOW)
			attributes.c_cflag |= tcflag_t(CLOCAL | CREAD) | tcflag_t(settings.dataBits == 7 ? CS7 : CS8)
			if settings.parity != .none { attributes.c_cflag |= tcflag_t(PARENB) }
			if settings.parity == .odd { attributes.c_cflag |= tcflag_t(PARODD) }
			if settings.stopBits == 2 { attributes.c_cflag |= tcflag_t(CSTOPB) }
			let speed = speed_t(settings.baud)
			guard cfsetispeed(&attributes, speed) == 0, cfsetospeed(&attributes, speed) == 0,
				  tcsetattr(fd, TCSANOW, &attributes) == 0 else {
				candidateErrors.append(Strings.Connection.portError(path: path, reason: Strings.Connection.configurationFailed(String(cString: strerror(errno)))))
				closePort()
				continue
			}
			decoder = StreamDecoder(ending: settings.ending)
			lastValid = MonotonicTime.now
			return true
		}
		let details = candidateErrors.isEmpty ? Strings.Connection.noPorts : candidateErrors.joined(separator: "\n")
		fail(Strings.Connection.connectionFailed(details))
		return false
	}

	private func poll() {
		let now = MonotonicTime.now
		if isDemo {
			guard now >= nextDemo else { return }
			nextDemo = now + 1
			demoCount += 1
			let power = 4.2 + sin(Double(demoCount) * 0.3) * 0.8
			let text = "\(demoCount);5,0;840;\(String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), power))\r\n"
			callback?(.batch(decoder.receive(Data(text.utf8), uptime: now, date: Date())))
			return
		}
		guard fd >= 0 else { return }
		var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
		let result = Darwin.poll(&descriptor, 1, 0)
		if result < 0 && errno != EINTR {
			portFailed(Strings.Connection.readFailed(String(cString: strerror(errno))))
			return
		}
		if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
			portFailed(Strings.Connection.unavailablePort)
			return
		}
		if descriptor.revents & Int16(POLLIN) != 0 {
			var buffer = [UInt8](repeating: 0, count: 8192)
			let count = Darwin.read(fd, &buffer, buffer.count)
			if count > 0 {
				let batch = decoder.receive(Data(buffer.prefix(count)), uptime: now, date: Date())
				let valid = batch.lines.contains {
					if case .reading = $0.value { return true }
					return false
				}
				if valid {
					lastValid = now
					if !validated {
						validated = true
						callback?(.ready(path))
					}
				}
				callback?(.batch(batch))
			} else if count < 0 && errno != EAGAIN && errno != EINTR {
				portFailed(Strings.Connection.readFailed(String(cString: strerror(errno))))
				return
			}
		}
		if now - lastValid >= settings.timeout {
			portFailed(Strings.Connection.timeout(Int(settings.timeout)))
		}
	}

	private func portFailed(_ reason: String) {
		if !validated && settings.port.isEmpty {
			candidateErrors.append(Strings.Connection.portError(path: path, reason: reason))
			_ = openNext()
		} else {
			fail(Strings.Connection.reconnect(path: path, reason: reason))
		}
	}
}
