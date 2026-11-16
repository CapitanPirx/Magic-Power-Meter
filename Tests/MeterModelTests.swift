import Observation
import XCTest
@testable import PowerMeterCore

private final class FakeTransport: SensorTransport, @unchecked Sendable {
	struct Connection {
		let settings: SerialSettings
		let demo: Bool
		let callback: @Sendable (TransportEvent) -> Void
	}

	private let lock = NSLock()
	private var discoveries: [@Sendable (Result<[String], SerialFailure>) -> Void] = []
	private var connections: [Connection] = []
	private var disconnections = 0

	var disconnectCount: Int { lock.withLock { disconnections } }
	var connectionRequests: [Connection] { lock.withLock { connections } }

	func discover(_ completion: @escaping @Sendable (Result<[String], SerialFailure>) -> Void) {
		lock.withLock { discoveries.append(completion) }
	}

	func connect(settings: SerialSettings, demo: Bool,
				 callback: @escaping @Sendable (TransportEvent) -> Void) {
		lock.withLock { connections.append(Connection(settings: settings, demo: demo, callback: callback)) }
	}

	func disconnect() {
		lock.withLock { disconnections += 1 }
	}

	func discover(_ result: Result<[String], SerialFailure>, request: Int) {
		let completion = lock.withLock { discoveries[request] }
		completion(result)
	}

	func emit(_ event: TransportEvent, connection: Int) {
		let callback = lock.withLock { connections[connection].callback }
		callback(event)
	}
}

@MainActor
private final class FakeExporter: MeasurementExporting {
	var requests: [ExportRequest] = []
	private var completions: [(@MainActor @Sendable (Result<[URL], Error>) -> Void)?] = []

	func write(_ request: ExportRequest,
			   completion: @escaping @MainActor @Sendable (Result<[URL], Error>) -> Void) {
		requests.append(request)
		completions.append(completion)
	}

	func complete(_ index: Int, with result: Result<[URL], Error>) {
		guard let completion = completions[index] else {
			preconditionFailure("An export completes exactly once")
		}
		completions[index] = nil
		completion(result)
	}
}

final class MeterModelTests: XCTestCase {
	@MainActor
	private func model(picker: @escaping @MainActor () -> URL? = { nil })
		-> (MeterModel, FakeTransport, FakeExporter, ExportFolder) {
		let transport = FakeTransport()
		let exporter = FakeExporter()
		let folder = ExportFolder(picker: picker)
		let model = MeterModel(transport: transport, exporter: exporter, exportFolder: folder)
		return (model, transport, exporter, folder)
	}

	@MainActor
	private func deliverCallbacks() async {
		await withCheckedContinuation { continuation in
			DispatchQueue.main.async { continuation.resume() }
		}
	}

	private func session(finalized: Bool = true) throws -> MeasurementSession {
		let date = Date(timeIntervalSince1970: 1_700_000_000)
		let condition = Condition(name: "База", iterations: 2)
		var session = MeasurementSession(mode: .comparison, conditions: [condition], duration: 3, timeout: 8,
										 source: .demo, connectionDescription: "fake", createdAt: date)
		for number in 1...2 {
			let start = Double(number * 10)
			try session.start(IterationKey(conditionID: condition.id, number: number), uptime: start, date: date)
			session.receive(SensorBatch(raw: Data([UInt8(number), 0xFF]), lines: [
				TimedLine(value: .reading(SensorReading(count: 1, voltage: 5, current: 2, power: 3)), beganAt: start)
			], uptime: start + 1, date: date))
			session.tick(uptime: start + 3, date: date)
		}
		if finalized { session.finalize(uptime: 24, date: date) }
		return session
	}

	@MainActor
	func testDiscoveryAndConnectionUseInjectedTransportAndCurrentSettings() async {
		let (model, transport, _, _) = model()
		transport.discover(.success(["/dev/fake-a", "/dev/fake-b"]), request: 0)
		await deliverCallbacks()
		XCTAssertEqual(model.ports, ["/dev/fake-a", "/dev/fake-b"])
		model.refreshPorts()
		transport.discover(.failure(SerialFailure(message: "discovery failed")), request: 1)
		await deliverCallbacks()
		XCTAssertEqual(model.error, "discovery failed")
		XCTAssertEqual(model.ports, ["/dev/fake-a", "/dev/fake-b"])
		model.settings.port = "/dev/fake-b"
		model.settings.baud = 115200
		model.settings.parity = .even
		model.demo = true
		let settings = model.settings
		model.connect()
		XCTAssertTrue(model.preparing)
		XCTAssertNil(model.error)
		XCTAssertEqual(transport.connectionRequests.count, 1)
		XCTAssertEqual(transport.connectionRequests[0].settings, settings)
		XCTAssertTrue(transport.connectionRequests[0].demo)
		model.settings.baud = 9600
		XCTAssertEqual(transport.connectionRequests[0].settings.baud, 115200)
		transport.emit(.preparing("preparing fake"), connection: 0)
		await deliverCallbacks()
		XCTAssertEqual(model.connectionStatus, "preparing fake")
		transport.emit(.ready("fake source"), connection: 0)
		await deliverCallbacks()
		XCTAssertTrue(model.connected)
		XCTAssertFalse(model.preparing)
		XCTAssertEqual(model.connectedPort, "fake source")
		XCTAssertEqual(model.connectionStatus, "Демонстрация · не реальные измерения")
	}

	@MainActor
	func testStaleConnectionsCannotChangeStateOrAppendSamplesAfterReconnectOrDisconnect() async throws {
		let (model, transport, _, _) = model()
		model.demo = true
		model.minutes = 0
		model.seconds = 30
		model.connect()
		model.connect()
		transport.emit(.ready("current"), connection: 1)
		await deliverCallbacks()
		model.createSession()
		model.start()
		defer { model.disconnect() }
		XCTAssertTrue(model.recording)
		let now = MonotonicTime.now
		let batch = SensorBatch(raw: Data("1;5;2;3\n".utf8), lines: [
			TimedLine(value: .reading(SensorReading(count: 1, voltage: 5, current: 2, power: 3)), beganAt: now)
		], uptime: now, date: Date())
		for event: TransportEvent in [.preparing("stale"), .ready("stale"), .batch(batch), .failure("stale")] {
			transport.emit(event, connection: 0)
		}
		await deliverCallbacks()
		XCTAssertTrue(model.connected)
		XCTAssertTrue(model.recording)
		XCTAssertEqual(model.connectedPort, "current")
		XCTAssertNil(model.error)
		XCTAssertEqual(model.preview, "")
		XCTAssertTrue(try XCTUnwrap(model.session?.active).samples.isEmpty)
		transport.emit(.batch(batch), connection: 1)
		await deliverCallbacks()
		XCTAssertEqual(model.preview, "1;5;2;3\n")
		XCTAssertEqual(model.session?.active?.samples.count, 1)
		model.disconnect()
		XCTAssertFalse(model.recording)
		XCTAssertEqual(model.session?.attempts.last?.stopReason, "Подключение отключено — исключено из расчётов")
		transport.emit(.ready("late"), connection: 1)
		transport.emit(.failure("late error"), connection: 1)
		transport.emit(.batch(batch), connection: 1)
		await deliverCallbacks()
		XCTAssertFalse(model.connected)
		XCTAssertFalse(model.preparing)
		XCTAssertEqual(model.connectionStatus, "Отключено")
		XCTAssertEqual(model.connectedPort, "Не подключён")
		XCTAssertNil(model.error)
		XCTAssertEqual(model.session?.attempts.last?.samples.count, 1)
	}

	@MainActor
	func testCurrentFailureStopsAttemptWithoutSubstitutingDemoOrIncludingIt() async {
		let (model, transport, _, _) = model()
		model.minutes = 0
		model.seconds = 30
		model.connect()
		transport.emit(.ready("/dev/fake"), connection: 0)
		await deliverCallbacks()
		model.createSession()
		model.start()
		transport.emit(.failure("sensor unavailable"), connection: 0)
		await deliverCallbacks()
		XCTAssertFalse(model.connected)
		XCTAssertFalse(model.recording)
		XCTAssertFalse(model.demo)
		XCTAssertEqual(model.session?.source, .serial)
		XCTAssertEqual(model.session?.completedIterations, 0)
		XCTAssertEqual(model.session?.attempts.last?.stopReason, "sensor unavailable — исключено из расчётов")
		XCTAssertEqual(model.error, "sensor unavailable")
		XCTAssertEqual(transport.connectionRequests.count, 1)
	}

	@MainActor
	func testModelReleaseDisconnectsInjectedTransport() {
		let transport = FakeTransport()
		var model: MeterModel? = MeterModel(transport: transport, exporter: FakeExporter(),
											exportFolder: ExportFolder(picker: { nil }))
		XCTAssertNotNil(model)
		model = nil
		XCTAssertEqual(transport.disconnectCount, 1)
	}

	@MainActor
	func testFinalizationAndSelectedExportCaptureIndependentImmutableRequests() throws {
		let (model, _, exporter, folder) = model()
		let first = URL(fileURLWithPath: "/tmp/first")
		let second = URL(fileURLWithPath: "/tmp/second")
		folder.url = first
		model.session = try session(finalized: false)
		model.finalize()
		let original = try XCTUnwrap(model.session)
		let csv = try XCTUnwrap(model.generatedCSV)
		XCTAssertEqual(model.pendingWrites, 1)
		XCTAssertEqual(exporter.requests[0].contents, .resultAndLogs)
		model.folder = second
		let selected = IterationKey(conditionID: original.conditions[0].id, number: 2)
		model.select(selected)
		model.exportLogs(selectedOnly: true)
		XCTAssertEqual(model.pendingWrites, 2)
		XCTAssertEqual(exporter.requests[1].contents, .logs(selected))
		XCTAssertEqual(exporter.requests[1].folder, second)
		model.newSession()
		model.demo = false
		model.createSession()
		XCTAssertNotEqual(model.session?.id, original.id)
		XCTAssertEqual(exporter.requests[0].session.id, original.id)
		XCTAssertTrue(exporter.requests[0].session.finalized)
		XCTAssertEqual(exporter.requests[0].session.attempts.count, 2)
		XCTAssertEqual(exporter.requests[0].session.attempts[1].chunks[0].data, Data([2, 0xFF]))
		XCTAssertEqual(exporter.requests[0].folder, first)
		XCTAssertEqual(MeasurementExport.csv(exporter.requests[0].session), csv)
		exporter.complete(0, with: .success([first.appendingPathComponent("result.csv")]))
		XCTAssertEqual(model.pendingWrites, 1)
		XCTAssertEqual(model.notice, "Сохранено:\n/tmp/first/result.csv")
		exporter.complete(1, with: .success([second.appendingPathComponent("logs")]))
		XCTAssertEqual(model.pendingWrites, 0)
		XCTAssertEqual(model.notice, "Сохранено:\n/tmp/second/logs")
	}

	@MainActor
	func testExportFailureKeepsCSVAndSessionForExplicitRetry() throws {
		let (model, _, exporter, _) = model()
		model.folder = URL(fileURLWithPath: "/tmp/results")
		model.saveRaw = false
		model.session = try session(finalized: false)
		model.finalize()
		XCTAssertEqual(exporter.requests[0].contents, .result)
		let id = model.session?.id
		let csv = model.generatedCSV
		model.notice = nil
		exporter.complete(0, with: .failure(NSError(domain: "test.export", code: 9,
												  userInfo: [NSLocalizedDescriptionKey: "disk full"])))
		XCTAssertEqual(model.pendingWrites, 0)
		XCTAssertNil(model.notice)
		XCTAssertEqual(model.error, "Не удалось сохранить файлы: disk full. Данные остались в памяти; повторите экспорт.")
		XCTAssertEqual(model.session?.id, id)
		XCTAssertEqual(model.generatedCSV, csv)
		model.exportResult()
		XCTAssertNil(model.error)
		XCTAssertEqual(model.pendingWrites, 1)
		XCTAssertEqual(exporter.requests[1].session.id, id)
		XCTAssertEqual(exporter.requests[1].contents, .result)
		exporter.complete(1, with: .success([URL(fileURLWithPath: "/tmp/results/retry.csv")]))
		XCTAssertEqual(model.pendingWrites, 0)
		XCTAssertEqual(model.notice, "Сохранено:\n/tmp/results/retry.csv")
		XCTAssertEqual(model.generatedCSV, csv)
	}

	@MainActor
	func testPickerCancellationDoesNotQueueWritesOrLoseFolderOrData() throws {
		var choices: [URL?] = [nil, URL(fileURLWithPath: "/tmp/chosen"), nil]
		let (model, _, exporter, _) = model(picker: { choices.removeFirst() })
		model.session = try session(finalized: false)
		model.finalize()
		let csv = model.generatedCSV
		model.exportResult()
		XCTAssertNil(model.folder)
		XCTAssertTrue(exporter.requests.isEmpty)
		XCTAssertEqual(model.pendingWrites, 0)
		XCTAssertEqual(model.generatedCSV, csv)
		model.exportResult()
		XCTAssertEqual(model.folder?.path, "/tmp/chosen")
		XCTAssertEqual(exporter.requests.count, 1)
		XCTAssertEqual(exporter.requests[0].contents, .result)
		XCTAssertEqual(model.notice, "Папка выбрана. Запись будет подтверждена отдельно.")
		model.chooseFolder()
		XCTAssertEqual(model.folder?.path, "/tmp/chosen")
		XCTAssertEqual(exporter.requests.count, 1)
		exporter.complete(0, with: .success([URL(fileURLWithPath: "/tmp/chosen/result.csv")]))
		XCTAssertEqual(model.pendingWrites, 0)
		XCTAssertEqual(model.generatedCSV, csv)
	}

	@MainActor
	func testSelectedExportWithoutSelectionDoesNotOpenPicker() throws {
		var pickerCalls = 0
		let (model, _, exporter, _) = model(picker: { pickerCalls += 1; return nil })
		model.session = try session()
		model.exportLogs(selectedOnly: true)
		XCTAssertEqual(pickerCalls, 0)
		XCTAssertTrue(exporter.requests.isEmpty)
		XCTAssertEqual(model.pendingWrites, 0)
	}

	@MainActor
	func testStoppedAttemptQueuesRawSnapshotOnlyWhenEnabled() async throws {
		let (model, transport, exporter, _) = model()
		model.folder = URL(fileURLWithPath: "/tmp/raw")
		model.minutes = 0
		model.seconds = 30
		model.demo = true
		model.connect()
		transport.emit(.ready("demo fake"), connection: 0)
		await deliverCallbacks()
		model.createSession()
		model.start()
		model.stop()
		XCTAssertEqual(exporter.requests.count, 1)
		XCTAssertEqual(exporter.requests[0].contents, .logs(nil))
		XCTAssertFalse(try XCTUnwrap(exporter.requests[0].session.attempts.first).complete)
		XCTAssertNil(exporter.requests[0].session.active)
		model.saveRaw = false
		model.start()
		model.stop()
		XCTAssertEqual(exporter.requests.count, 1)
		XCTAssertEqual(model.session?.attempts.count, 2)
		XCTAssertEqual(exporter.requests[0].session.attempts.count, 1)
		exporter.complete(0, with: .success([URL(fileURLWithPath: "/tmp/raw/attempts")]))
		XCTAssertEqual(model.pendingWrites, 0)
	}

	@MainActor
	func testFolderChangesRemainObservableThroughModel() async {
		let (model, _, _, folder) = model()
		let changed = expectation(description: "UI observes the injected folder")
		withObservationTracking {
			XCTAssertNil(model.folder)
		} onChange: {
			changed.fulfill()
		}
		folder.url = URL(fileURLWithPath: "/tmp/observable")
		await fulfillment(of: [changed], timeout: 1)
		XCTAssertEqual(model.folder?.path, "/tmp/observable")
	}
}
