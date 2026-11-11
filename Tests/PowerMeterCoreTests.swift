import XCTest
@testable import PowerMeterCore

final class PowerMeterCoreTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testParserAndChunkBoundaries() {
        var decoder = StreamDecoder()
        XCTAssertTrue(decoder.receive(Data("count;voltage_V;current_mA;power_W\r".utf8), uptime: 0, date: date).lines.isEmpty)
        let batch = decoder.receive(Data("\n1;5,2;123.4;0,64\r\n2;5;4;nan\ncount;voltage_V;current_mA;power_W\n".utf8), uptime: 1, date: date)
        XCTAssertEqual(batch.lines.count, 4)
        XCTAssertEqual(batch.lines[0].value, .header)
        XCTAssertEqual(batch.lines[1].value, .reading(SensorReading(count: 1, voltage: 5.2, current: 123.4, power: 0.64)))
        guard case .invalid = batch.lines[2].value else { return XCTFail("NaN accepted") }
        XCTAssertEqual(batch.lines[3].value, .header)
        XCTAssertEqual(batch.lines[0].beganAt, 0)
    }

    func testLineEndingsAndOversizedInput() {
        for ending in LineEnding.allCases {
            var decoder = StreamDecoder(ending: ending)
            let data = Data("1;5;2;3".utf8) + Data(ending.delimiter)
            XCTAssertEqual(decoder.receive(data, uptime: 0, date: date).lines.count, 1)
        }
        var decoder = StreamDecoder()
        let oversized = decoder.receive(Data(repeating: 65, count: 5000), uptime: 0, date: date)
        XCTAssertEqual(oversized.lines.count, 1)
        let recovered = decoder.receive(Data("\n1;5;2;3\n".utf8), uptime: 1, date: date)
        XCTAssertEqual(recovered.lines.count, 1)
    }

    func makeSession(iterations: [Int] = [2, 1]) -> MeasurementSession {
        MeasurementSession(conditions: iterations.enumerated().map {
            Condition(name: $0.offset == 0 ? "База; \"A\"" : "Новое\nусловие", iterations: $0.element)
        }, duration: 3, timeout: 8, source: .demo, connectionDescription: "DEMO", createdAt: date)
    }

    func record(_ session: inout MeasurementSession, condition: Int, iteration: Int, power: Double,
                start: Double = 0) throws {
        let key = IterationKey(conditionID: session.conditions[condition].id, number: iteration)
        try session.start(key, uptime: start, date: date)
        var decoder = StreamDecoder()
        for offset in 0..<3 {
            session.receive(decoder.receive(Data("\(offset);5;2;\(power)\r\n".utf8),
                                            uptime: start + Double(offset), date: date.addingTimeInterval(Double(offset))))
        }
        session.tick(uptime: start + 3, date: date.addingTimeInterval(3))
    }

    func testTimerUsesMonotonicTimeNotSampleCountOrWallClock() throws {
        var session = makeSession()
        let key = IterationKey(conditionID: session.conditions[0].id, number: 1)
        try session.start(key, uptime: 100, date: date)
        var decoder = StreamDecoder()
        session.receive(decoder.receive(Data("1;5;2;4\n2;5;2;6\n".utf8), uptime: 101, date: date))
        session.tick(uptime: 102, date: date.addingTimeInterval(50_000))
        XCTAssertNotNil(session.active)
        session.tick(uptime: 103, date: date.addingTimeInterval(-50_000))
        XCTAssertNil(session.active)
        XCTAssertTrue(session.attempts[0].complete)
        XCTAssertEqual(session.attempts[0].elapsed, 3)
        XCTAssertEqual(session.attempts[0].endedAt, date.addingTimeInterval(-50_000))
    }

    func testManualStopRetryAndEarlyFinalizePreserveRawData() throws {
        var session = makeSession()
        let key = IterationKey(conditionID: session.conditions[0].id, number: 1)
        try session.start(key, uptime: 0, date: date)
        var decoder = StreamDecoder()
        let raw = Data("broken\r\n1;5;2;99\r\n".utf8)
        session.receive(decoder.receive(raw, uptime: 1, date: date))
        session.stop(uptime: 1, date: date)
        XCTAssertNil(session.mean(conditionID: key.conditionID))
        try record(&session, condition: 0, iteration: 1, power: 4, start: 5)
        XCTAssertEqual(session.attempts.count, 2)
        XCTAssertEqual(session.attempts[0].chunks[0].data, raw)
        XCTAssertEqual(session.attempts[1].number, 2)
        XCTAssertEqual(session.mean(conditionID: key.conditionID), 4)
        session.finalize(uptime: 9, date: date)
        XCTAssertTrue(session.incomplete)
        XCTAssertThrowsError(try session.start(key, uptime: 10, date: date))
    }

    func testEmptyRunAndMissingCoverageCannotComplete() throws {
        var session = makeSession()
        let key = IterationKey(conditionID: session.conditions[0].id, number: 1)
        try session.start(key, uptime: 0, date: date)
        session.tick(uptime: 10, date: date)
        XCTAssertFalse(session.attempts[0].complete)
        XCTAssertNil(session.attempts[0].mean)
        XCTAssertEqual(session.completedIterations, 0)
    }

    func testFinalizeWhileRecordingExcludesActiveAttempt() throws {
        var session = makeSession()
        let key = IterationKey(conditionID: session.conditions[0].id, number: 1)
        try session.start(key, uptime: 0, date: date)
        var decoder = StreamDecoder()
        let raw = Data("1;5;2;8\n".utf8)
        session.receive(decoder.receive(raw, uptime: 1, date: date))
        session.finalize(uptime: 1.5, date: date)
        XCTAssertTrue(session.finalized)
        XCTAssertTrue(session.incomplete)
        XCTAssertNil(session.active)
        XCTAssertNil(session.mean(conditionID: key.conditionID))
        XCTAssertEqual(session.attempts[0].chunks[0].data, raw)
        XCTAssertEqual(session.attempts[0].stoppedAfter, 1.5)
        XCTAssertTrue(session.attempts[0].stopReason?.contains("досрочно") == true)
    }

    func testManualStopAfterDeadlineHonorsCompletedWindow() throws {
        var session = makeSession()
        let key = IterationKey(conditionID: session.conditions[0].id, number: 1)
        try session.start(key, uptime: 0, date: date)
        var decoder = StreamDecoder()
        session.receive(decoder.receive(Data("1;5;2;5\n".utf8), uptime: 0.1, date: date))
        session.receive(decoder.receive(Data("2;5;2;5\n".utf8), uptime: 2, date: date))
        session.stop(uptime: 3.2, date: date.addingTimeInterval(3.2))
        XCTAssertTrue(session.attempts[0].complete)
        XCTAssertEqual(session.attempts[0].elapsed, 3)
        XCTAssertEqual(session.attempts[0].stoppedAfter, 3.2)
    }

    func testTimeoutGapsCorruptionAndResetAreVisible() throws {
        let condition = Condition(name: "База", iterations: 1)
        var session = MeasurementSession(conditions: [condition], duration: 30, timeout: 3,
                                         source: .serial, connectionDescription: "PTY")
        try session.start(IterationKey(conditionID: condition.id, number: 1), uptime: 0, date: date)
        var decoder = StreamDecoder()
        session.receive(decoder.receive(Data("10;5;2;1\n12;5;2;2\n1;5;2;3\nbroken\n".utf8), uptime: 1, date: date))
        XCTAssertEqual(session.active?.warnings.count, 3)
        XCTAssertEqual(session.active?.missingReadings, 1)
        session.tick(uptime: 4, date: date)
        XCTAssertNil(session.active)
        XCTAssertEqual(session.attempts[0].stopReason, "Таймаут показаний")
        XCTAssertFalse(session.attempts[0].complete)
    }

    func testBoundaryBytesAreLoggedButPreStartPartialLineIsNotSampled() throws {
        var session = makeSession()
        var decoder = StreamDecoder()
        _ = decoder.receive(Data("1;5;2;".utf8), uptime: 0, date: date)
        let key = IterationKey(conditionID: session.conditions[0].id, number: 1)
        try session.start(key, uptime: 0.5, date: date)
        let raw = Data("100\n2;5;2;6\n".utf8)
        session.receive(decoder.receive(raw, uptime: 1, date: date))
        XCTAssertEqual(session.active?.samples.count, 1)
        XCTAssertEqual(session.active?.mean, 6)
        XCTAssertEqual(session.active?.chunks[0].data, raw)
        session.receive(decoder.receive(Data("3;5;2;99\n".utf8), uptime: 3.5, date: date))
        XCTAssertNil(session.active)
        XCTAssertEqual(session.attempts[0].samples.count, 1)
    }

    func testUnequalIterationsAndDeltasFromMeans() throws {
        var session = makeSession()
        try record(&session, condition: 0, iteration: 1, power: 2)
        try record(&session, condition: 0, iteration: 2, power: 6, start: 4)
        try record(&session, condition: 1, iteration: 1, power: 6, start: 8)
        let rows = MeasurementExport.rows(session)
        XCTAssertEqual(rows[1].values[0], 6)
        XCTAssertNil(rows[1].values[1])
        XCTAssertEqual(rows.last?.values[0], 4)
        XCTAssertEqual(rows.last?.values[1], 6)
        XCTAssertEqual(Numeric.percent(6, base: 4), 50)
        XCTAssertNil(Numeric.delta(6, base: nil))
        XCTAssertNil(Numeric.percent(6, base: 0))
        XCTAssertEqual(Numeric.delta(6, base: 0), 6)
    }

    func testMissingBaseAndCSVMetadataEscaping() throws {
        var session = makeSession()
        try record(&session, condition: 1, iteration: 1, power: 6.5)
        session.finalize(uptime: 4, date: date)
        let data = MeasurementExport.csv(session)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertTrue(text.contains("\"База; \"\"A\"\", Вт\""))
        XCTAssertTrue(text.contains("6,500;;;Неполный результат"))
        XCTAssertTrue(text.contains("ДЕМО"))
        XCTAssertTrue(text.contains("1;;6,500;;;"))
        XCTAssertNil(session.mean(conditionID: session.conditions[0].id))
    }

    func testRawLogIsExactAndMetadataIdentifiesEveryAttempt() throws {
        var session = makeSession()
        try record(&session, condition: 0, iteration: 1, power: 5)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = try MeasurementExport.writeLogs(session, folder: folder)
        let raw = try Data(contentsOf: output.appendingPathComponent("DEMO-condition-1-iteration-1-attempt-1.txt"))
        XCTAssertEqual(raw, session.attempts[0].chunks.reduce(into: Data()) { $0.append($1.data) })
        let metadata = try Data(contentsOf: output.appendingPathComponent("DEMO-condition-1-iteration-1-attempt-1.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        XCTAssertEqual(json["complete"] as? Bool, true)
        XCTAssertEqual(json["source"] as? String, MeasurementSource.demo.rawValue)
        XCTAssertEqual((json["chunks"] as? [[String: Any]])?.count, 3)
        let csv = try MeasurementExport.writeResult(session, folder: folder)
        XCTAssertEqual(try Data(contentsOf: csv), MeasurementExport.csv(session))
    }

    func testSelectedLogExportRetainsOverallCompleteness() throws {
        var session = makeSession(iterations: [1, 1])
        try record(&session, condition: 0, iteration: 1, power: 2)
        try record(&session, condition: 1, iteration: 1, power: 3, start: 5)
        session.finalize(uptime: 9, date: date)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = IterationKey(conditionID: session.conditions[0].id, number: 1)
        let output = try MeasurementExport.writeLogs(session, folder: folder, key: key)
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        let jsonURL = try XCTUnwrap(files.first { $0.pathExtension == "json" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        XCTAssertEqual(json["incomplete_result"] as? Bool, false)
    }

    func testFrequencyIsComputedFromActualTimes() throws {
        var session = makeSession()
        try record(&session, condition: 0, iteration: 1, power: 2)
        XCTAssertEqual(session.attempts[0].frequency, 1)
        XCTAssertEqual(session.attempts[0].missingReadings, 0)
    }

    func testStableMeanAndUnrepresentablePercentage() {
        let large = Double.greatestFiniteMagnitude
        XCTAssertEqual(Numeric.mean([large, large]), large)
        XCTAssertNil(Numeric.mean([]))
        XCTAssertEqual(Numeric.percent(3, base: 2), 50)
        XCTAssertNil(Numeric.percent(large, base: .leastNonzeroMagnitude))
    }
}
