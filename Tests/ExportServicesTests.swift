import XCTest
@testable import PowerMeterCore

final class ExportServicesTests: XCTestCase {
	private func session() throws -> MeasurementSession {
		let date = Date(timeIntervalSince1970: 1_700_000_000)
		let condition = Condition(name: "База", iterations: 2)
		var session = MeasurementSession(conditions: [condition], duration: 3, timeout: 8,
										 source: .demo, connectionDescription: "test", createdAt: date)
		for number in 1...2 {
			let start = Double(number * 10)
			try session.start(IterationKey(conditionID: condition.id, number: number), uptime: start, date: date)
			session.receive(SensorBatch(raw: Data([UInt8(number), 0xFF]), lines: [
				TimedLine(value: .reading(SensorReading(count: 1, voltage: 5, current: 2, power: 3)), beganAt: start)
			], uptime: start + 1, date: date))
			session.tick(uptime: start + 3, date: date)
		}
		return session
	}

	@MainActor
	private func write(_ request: ExportRequest, using exporter: any MeasurementExporting) async throws -> [URL] {
		try await withCheckedThrowingContinuation { continuation in
			exporter.write(request) { result in continuation.resume(with: result) }
		}
	}

	@MainActor
	func testQueuedExportWritesOrderedResultAndExactLogs() async throws {
		let session = try session()
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: folder) }
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let exporter = FileMeasurementExporter()
		let urls = try await write(ExportRequest(session: session, folder: folder, contents: .resultAndLogs), using: exporter)
		XCTAssertEqual(urls.count, 2)
		XCTAssertEqual(urls[0].pathExtension, "csv")
		XCTAssertEqual(try Data(contentsOf: urls[0]), MeasurementExport.csv(session))
		XCTAssertTrue(urls[1].lastPathComponent.hasSuffix("-raw"))
		for number in 1...2 {
			XCTAssertEqual(try Data(contentsOf: urls[1].appendingPathComponent("DEMO-condition-1-iteration-\(number)-attempt-1.txt")),
						   Data([UInt8(number), 0xFF]))
		}
	}

	@MainActor
	func testSelectedLogRequestDoesNotExportOtherIterationsOrCSV() async throws {
		let session = try session()
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: folder) }
		let key = IterationKey(conditionID: session.conditions[0].id, number: 2)
		let urls = try await write(ExportRequest(session: session, folder: folder, contents: .logs(key)),
								  using: FileMeasurementExporter())
		XCTAssertEqual(urls.count, 1)
		let files = try FileManager.default.contentsOfDirectory(atPath: urls[0].path).sorted()
		XCTAssertEqual(files, ["DEMO-condition-1-iteration-2-attempt-1.json", "DEMO-condition-1-iteration-2-attempt-1.txt"])
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
	}

	@MainActor
	func testExportPropagatesOriginalFileErrorAndKeepsEarlierResult() async throws {
		let session = try session()
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: folder) }
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let raw = folder.appendingPathComponent(MeasurementExport.filePrefix(session) + "-raw")
		try Data([0]).write(to: raw)
		var expected: NSError?
		do { _ = try MeasurementExport.writeLogs(session, folder: folder) }
		catch { expected = error as NSError }
		let fileError = try XCTUnwrap(expected)
		do {
			_ = try await write(ExportRequest(session: session, folder: folder, contents: .resultAndLogs),
								using: FileMeasurementExporter())
			XCTFail("Export failure reported as success")
		} catch {
			XCTAssertEqual((error as NSError).domain, fileError.domain)
			XCTAssertEqual((error as NSError).code, fileError.code)
			XCTAssertEqual(error.localizedDescription, fileError.localizedDescription)
		}
		let csv = folder.appendingPathComponent(MeasurementExport.filePrefix(session) + ".csv")
		XCTAssertEqual(try Data(contentsOf: csv), MeasurementExport.csv(session))
		XCTAssertEqual(try Data(contentsOf: raw), Data([0]))
	}

	@MainActor
	func testFolderSelectionIsInjectableAndCancellationKeepsPreviousURL() {
		let first = URL(fileURLWithPath: "/tmp/first")
		let second = URL(fileURLWithPath: "/tmp/second")
		var selections: [URL?] = [nil, second]
		let destination = ExportFolder(picker: { selections.removeFirst() })
		destination.url = first
		XCTAssertFalse(destination.choose())
		XCTAssertEqual(destination.url, first)
		XCTAssertTrue(destination.choose())
		XCTAssertEqual(destination.url, second)
		XCTAssertTrue(selections.isEmpty)
	}
}
