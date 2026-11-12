import AppKit
import Darwin
import Foundation

enum SmokeFailure: Error, CustomStringConvertible {
	case failed(String)
	var description: String {
		switch self { case .failed(let message): return message }
	}
}

@MainActor
final class TransportProbe {
	var ready: [String] = []
	var batches: [SensorBatch] = []
	var failures: [String] = []
	var preparing: [String] = []

	func receive(_ event: TransportEvent) {
		switch event {
		case .ready(let path): ready.append(path)
		case .batch(let batch): batches.append(batch)
		case .failure(let message): failures.append(message)
		case .preparing(let message): preparing.append(message)
		}
	}
}

@main
struct DesktopSmoke {
	@MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
		guard value() else { throw SmokeFailure.failed(message) }
	}

	@MainActor static func wait(_ message: String, timeout: Double = 5,
								until predicate: () -> Bool) async throws {
		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		while !predicate() {
			if ProcessInfo.processInfo.systemUptime > deadline { throw SmokeFailure.failed("Timeout: \(message)") }
			try await Task.sleep(nanoseconds: 30_000_000)
		}
	}

	@MainActor static func main() {
		Task { @MainActor in
			do {
				try await serialTests()
				try await automaticSelectionTests()
				try modelTextTests()
				try await modelTests()
				print("PASS: serial PTY framing, readiness, busy port, disconnect, manual failure, timeout, automatic first-valid selection; demo session, retry, timer, CSV/log export, write errors, history")
				exit(0)
			} catch {
				fputs("FAIL: \(error)\n", stderr)
				exit(1)
			}
		}
		RunLoop.main.run()
	}

	@MainActor static func modelTextTests() throws {
		let model = MeterModel(transport: SerialTransport(), exporter: FileMeasurementExporter(),
							   exportFolder: ExportFolder(picker: { nil }))
		defer { model.disconnect() }
		try require(model.connectedPort == "Не подключён", "Initial port label")
		try require(model.connectionStatus == "Выберите источник и подключитесь", "Initial connection status")
		try require(model.conditions.map(\.name) == ["База", "Условие 1"], "Default condition names")
		try require(model.selectedName == "Итерация не выбрана", "Unselected iteration label")
		try require(SerialSettings().summary == "9600 бод · 8N1 · без flow control", "Serial summary")
		try require(SerialParity.allCases.map(\.rawValue) == ["Нет", "Чётная", "Нечётная"], "Parity labels")
		for parity in SerialParity.allCases {
			try require(SerialParity(rawValue: parity.rawValue) == parity, "Parity raw-value round trip")
		}
		try require(SerialParity(rawValue: "N") == nil, "Unknown parity label accepted")
		model.minutes = 0
		model.seconds = 0
		model.createSession()
		try require(model.error == "Укажите ненулевую длительность; секунды должны быть от 0 до 59.", "Duration error")
		model.seconds = 3
		model.createSession()
		try require(model.session?.conditions.first?.name == "Одиночный замер", "Single condition label")
		try require(model.selectedName == "Одиночный замер · итерация 1", "Selected iteration label")
		model.createSession()
		try require(model.error == "Сначала завершите текущую сессию и нажмите «Новый замер».", "Existing session error")
		model.finalize()
		try require(model.notice == "CSV сформирован в памяти. Выберите папку для сохранения на диск.", "CSV notice")
		model.newSession()
		model.comparison = true
		model.conditions[0].name = " "
		model.createSession()
		try require(model.error == "Задайте имена условий и от 1 до 50 итераций для каждого.", "Condition error")
		model.disconnect()
		try require(model.connectionStatus == "Отключено", "Disconnect status")
	}

	@MainActor static func serialTests() async throws {
		var master: Int32 = -1
		var slave: Int32 = -1
		var name = [CChar](repeating: 0, count: 1024)
		try require(openpty(&master, &slave, &name, nil, nil) == 0, "openpty")
		var masterOpen = true
		defer {
			if masterOpen { Darwin.close(master) }
			Darwin.close(slave)
		}
		let path = String(cString: name)
		let transport = SerialTransport()
		defer { transport.disconnect() }
		let probe = TransportProbe()
		var settings = SerialSettings()
		settings.port = path
		settings.timeout = 3
		transport.connect(settings: settings, demo: false) { event in
			Task { @MainActor in probe.receive(event) }
		}
		try await wait("serial preparing") { !probe.preparing.isEmpty }
		try await Task.sleep(nanoseconds: 100_000_000)
		let first = Data("count;voltage_V;current_mA;power_W\r\n1;5;2;".utf8)
		_ = first.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
		try await wait("header and partial bytes") { !probe.batches.isEmpty }
		try require(probe.ready.isEmpty, "A header / partial frame must not validate the sensor")
		let second = Data("3\n2;5,2;4,2;4,6\r\n".utf8)
		_ = second.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
		try await wait("valid readings") {
			probe.batches.flatMap(\.lines).filter { if case .reading = $0.value { return true }; return false }.count == 2
		}
		try require(probe.ready == [path], "Manual port must be validated exactly once")
		let raw = probe.batches.reduce(into: Data()) { $0.append($1.raw) }
		try require(raw == first + second, "Serial bytes changed")
		let competitor = SerialTransport()
		let busy = TransportProbe()
		competitor.connect(settings: settings, demo: false) { event in
			Task { @MainActor in busy.receive(event) }
		}
		try await wait("busy port reported") { !busy.failures.isEmpty }
		try require(busy.ready.isEmpty, "Busy port must not be accepted")
		competitor.disconnect()
		Darwin.close(master)
		masterOpen = false
		try await wait("unplug error") { !probe.failures.isEmpty }
		try require(probe.ready.count == 1, "Disconnected manual port was silently substituted")

		let missing = TransportProbe()
		settings.port = "/dev/magic-power-meter-nonexistent"
		transport.connect(settings: settings, demo: false) { event in
			Task { @MainActor in missing.receive(event) }
		}
		try await wait("missing port") { !missing.failures.isEmpty }
		try require(missing.ready.isEmpty && missing.batches.isEmpty, "Failed serial silently entered demo")

		var timeoutMaster: Int32 = -1
		var timeoutSlave: Int32 = -1
		var timeoutName = [CChar](repeating: 0, count: 1024)
		try require(openpty(&timeoutMaster, &timeoutSlave, &timeoutName, nil, nil) == 0, "timeout openpty")
		defer { Darwin.close(timeoutMaster); Darwin.close(timeoutSlave) }
		settings.port = String(cString: timeoutName)
		let timeoutProbe = TransportProbe()
		transport.connect(settings: settings, demo: false) { event in
			Task { @MainActor in timeoutProbe.receive(event) }
		}
		try await wait("silent device timeout", timeout: 5) { !timeoutProbe.failures.isEmpty }
		try require(timeoutProbe.ready.isEmpty, "Silent port was considered ready")
	}

	@MainActor static func modelTests() async throws {
		let model = MeterModel(transport: SerialTransport(), exporter: FileMeasurementExporter(),
							   exportFolder: ExportFolder(picker: { nil }))
		model.demo = true
		model.minutes = 0
		model.seconds = 3
		model.comparison = true
		model.conditions = [Condition(name: "База", iterations: 2), Condition(name: "Новое", iterations: 1)]
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MagicPowerMeter-smoke-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder); model.disconnect() }
		model.folder = folder
		model.connect()
		try await wait("demo ready") { model.connected }
		model.createSession()
		try require(model.session?.source == .demo, "Demo source not labelled")
		model.start()
		try await wait("first raw sample") { !(model.session?.active?.samples.isEmpty ?? true) }
		model.stop()
		try require(model.session?.completedIterations == 0, "Aborted iteration counted")
		for expected in 1...3 {
			model.nextIteration()
			try require(model.canStart, "Cannot start next iteration")
			model.start()
			try await wait("model monotonic timer", timeout: 5) { !model.recording }
			try require(model.session?.completedIterations == expected, "Timer did not complete a populated iteration")
		}
		try require(model.session?.attempts.count == 4, "Retry overwrote old raw attempt")
		model.finalize()
		try require(model.session?.finalized == true && model.session?.incomplete == false, "Finalization state")
		try require(model.generatedCSV != nil, "CSV not generated automatically")
		try await wait("automatic result and logs export") { model.pendingWrites == 0 }
		try require(model.error == nil, model.error ?? "Export error")
		let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
		try require(files.contains { $0.pathExtension == "csv" && $0.lastPathComponent.hasPrefix("DEMO-") }, "Missing labelled CSV")
		let rawDirectory = try files.first(where: { $0.lastPathComponent.hasSuffix("-raw") }).unwrap("Missing raw directory")
		let logs = try FileManager.default.contentsOfDirectory(atPath: rawDirectory.path)
		try require(logs.filter { $0.hasSuffix(".txt") }.count == 4, "Missing attempt logs")
		try require(logs.allSatisfy { $0.hasPrefix("DEMO-") }, "Unlabelled demo logs")

		let fileNotDirectory = folder.appendingPathComponent("not-a-directory")
		try Data().write(to: fileNotDirectory)
		model.folder = fileNotDirectory
		model.notice = nil
		model.exportResult()
		try await wait("write failure") { model.pendingWrites == 0 }
		try require(model.error != nil && model.notice == nil, "Write error reported as success")
		try require(model.generatedCSV != nil, "Write failure discarded in-memory result")
		let sessionID = try (model.session?.id).unwrap("Missing session")
		model.newSession()
		try require(model.history.count == 1 && model.session == nil, "Session not retained in history")
		model.showHistory(sessionID)
		try require(model.session?.finalized == true, "Finalized session not viewable")
	}

	@MainActor static func automaticSelectionTests() async throws {
		var firstMaster: Int32 = -1
		var firstSlave: Int32 = -1
		var firstName = [CChar](repeating: 0, count: 1024)
		var secondMaster: Int32 = -1
		var secondSlave: Int32 = -1
		var secondName = [CChar](repeating: 0, count: 1024)
		try require(openpty(&firstMaster, &firstSlave, &firstName, nil, nil) == 0, "first auto PTY")
		try require(openpty(&secondMaster, &secondSlave, &secondName, nil, nil) == 0, "second auto PTY")
		defer {
			Darwin.close(firstMaster); Darwin.close(firstSlave)
			Darwin.close(secondMaster); Darwin.close(secondSlave)
		}
		let first = String(cString: firstName)
		let second = String(cString: secondName)
		let transport = SerialTransport(portsProvider: { [first, second] })
		defer { transport.disconnect() }
		let probe = TransportProbe()
		var settings = SerialSettings()
		settings.timeout = 3
		transport.connect(settings: settings, demo: false) { event in
			Task { @MainActor in probe.receive(event) }
		}
		try await wait("first auto candidate") { probe.preparing.contains { $0.contains(first) } }
		let invalid = Data("count;voltage_V;current_mA;power_W\nnot-a-sensor\n".utf8)
		_ = invalid.withUnsafeBytes { Darwin.write(firstMaster, $0.baseAddress, $0.count) }
		try await wait("second auto candidate", timeout: 5) { probe.preparing.contains { $0.contains(second) } }
		try require(probe.ready.isEmpty, "First listed device was accepted without valid data")
		let valid = Data("1;5;123;0,615\n".utf8)
		_ = valid.withUnsafeBytes { Darwin.write(secondMaster, $0.baseAddress, $0.count) }
		try await wait("second device validates") { !probe.ready.isEmpty }
		try require(probe.ready == [second], "Auto-selection did not choose first valid sensor")
		try require(probe.failures.isEmpty, "Candidate timeout should not fail whole auto-selection")
	}
}

extension Optional {
	func unwrap(_ message: String) throws -> Wrapped {
		guard let self else { throw SmokeFailure.failed(message) }
		return self
	}
}
