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

	func testAttemptMeanPreservesAccumulationOrderAndSampleEdits() throws {
		let key = IterationKey(conditionID: UUID(), number: 1)
		var attempt = MeasurementAttempt(key: key, number: 1, startedAt: date, startUptime: 0)
		XCTAssertNil(attempt.mean)
		let powers = [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, 0, 0.1, 15.5]
		var expected = 0.0
		for (index, power) in powers.enumerated() {
			attempt.samples.append(PowerSample(elapsed: Double(index), date: date,
											   reading: SensorReading(count: UInt64(index), voltage: 5,
																	  current: 2, power: power)))
			expected += (power - expected) / Double(index + 1)
			XCTAssertEqual(try XCTUnwrap(attempt.mean).bitPattern, expected.bitPattern)
		}
		let snapshot = attempt
		attempt.samples = [PowerSample(elapsed: 0, date: date,
										reading: SensorReading(count: 0, voltage: 5, current: 2, power: 0.125))]
		XCTAssertEqual(attempt.mean, 0.125)
		XCTAssertEqual(try XCTUnwrap(snapshot.mean).bitPattern, expected.bitPattern)
		attempt.samples.removeAll()
		XCTAssertNil(attempt.mean)
	}

	func testConditionMeanUsesCompletedIterationMeansInRecordingOrder() throws {
		var session = makeSession(iterations: [4, 1])
		let conditionID = session.conditions[0].id
		let retriedKey = IterationKey(conditionID: conditionID, number: 2)
		try session.start(retriedKey, uptime: 0, date: date)
		var decoder = StreamDecoder()
		session.receive(decoder.receive(Data("1;5;2;999\n".utf8), uptime: 1, date: date))
		session.stop(uptime: 2, date: date)

		func complete(_ iteration: Int, powers: [Double], start: Double) throws {
			try session.start(IterationKey(conditionID: conditionID, number: iteration), uptime: start, date: date)
			for (index, power) in powers.enumerated() {
				session.receive(decoder.receive(Data("\(index);5;2;\(power)\n".utf8),
												uptime: start + (powers.count == 1 ? 1 : Double(index)), date: date))
			}
			session.tick(uptime: start + 3, date: date)
		}
		try complete(3, powers: [1e16], start: 5)
		try record(&session, condition: 1, iteration: 1, power: 99, start: 10)
		try complete(1, powers: [1, 1, 1], start: 15)
		try complete(2, powers: [0.125, 0.125], start: 20)
		try session.start(IterationKey(conditionID: conditionID, number: 4), uptime: 25, date: date)
		session.receive(decoder.receive(Data("1;5;2;999\n".utf8), uptime: 26, date: date))

		let expected = [1e16, 1, 0.125].enumerated().reduce(0.0) {
			$0 + ($1.element - $0) / Double($1.offset + 1)
		}
		XCTAssertEqual(try XCTUnwrap(session.mean(conditionID: conditionID)).bitPattern, expected.bitPattern)
		XCTAssertEqual(session.mean(conditionID: session.conditions[1].id), 99)
		XCTAssertNil(session.mean(conditionID: UUID()))
		XCTAssertEqual(session.completedIterations, 4)
		XCTAssertEqual(session.totalIterations, 5)
		XCTAssertTrue(session.incomplete)
		let rows = MeasurementExport.rows(session)
		XCTAssertEqual(rows.map(\.label), ["1", "2", "3", "4", "Среднее"])
		XCTAssertEqual(rows[0].values[0], 1)
		XCTAssertEqual(rows[1].values[0], 0.125)
		XCTAssertEqual(rows[2].values[0], 1e16)
		XCTAssertNil(rows[3].values[0])
		XCTAssertEqual(try XCTUnwrap(rows[4].values[0]).bitPattern, expected.bitPattern)
	}

	func testCSVBytesPreserveZeroBaseEscapingAndMeanDeltas() throws {
		var session = MeasurementSession(conditions: [
			Condition(name: "База; \"A\"", iterations: 2), Condition(name: "Новое условие", iterations: 1)
		], duration: 3, timeout: 8, source: .demo, connectionDescription: "DEMO", createdAt: date)
		try record(&session, condition: 0, iteration: 1, power: 0)
		try record(&session, condition: 0, iteration: 2, power: 4, start: 5)
		try record(&session, condition: 1, iteration: 1, power: 6.5, start: 10)
		let expected = [
			"Итерация;\"База; \"\"A\"\", Вт\";Новое условие, Вт;Новое условие: Δ к базе, Вт;Новое условие: Δ к базе, %;Результат;Источник;Комплектность",
			"1;0,000;6,500;6,500;;Полный результат;ДЕМО — СИНТЕТИЧЕСКИЕ ДАННЫЕ;3/3",
			"2;4,000;;;;Полный результат;ДЕМО — СИНТЕТИЧЕСКИЕ ДАННЫЕ;3/3",
			"Среднее;2,000;6,500;4,500;225,000;Полный результат;ДЕМО — СИНТЕТИЧЕСКИЕ ДАННЫЕ;3/3"
		].joined(separator: "\r\n")
		XCTAssertEqual(MeasurementExport.csv(session), Data(("\u{FEFF}" + expected + "\r\n").utf8))
	}

	func testRawLogBytesAndFullMetadataForStoppedAndActiveRetries() throws {
		var session = makeSession(iterations: [1])
		let key = IterationKey(conditionID: session.conditions[0].id, number: 1)
		try session.start(key, uptime: 0, date: date, connectionDescription: "first connection")
		let first = Data([0xFF, 0x00, 0x0D])
		let second = Data("1;5;2;3\r\n".utf8)
		session.receive(SensorBatch(raw: first, lines: [], uptime: 0.25, date: date.addingTimeInterval(0.125)))
		session.receive(SensorBatch(raw: second, lines: [
			TimedLine(value: .reading(SensorReading(count: 1, voltage: 5, current: 2, power: 3)), beganAt: 1)
		], uptime: 1, date: date.addingTimeInterval(1.875)))
		session.stop(uptime: 1.75, date: date.addingTimeInterval(2.25), reason: "retry requested")
		try session.start(key, uptime: 10, date: date.addingTimeInterval(10.5),
						  connectionDescription: "second connection")
		session.receive(SensorBatch(raw: Data([1, 2]), lines: [], uptime: 10.125,
									date: date.addingTimeInterval(11.999)))
		session.receive(SensorBatch(raw: Data(), lines: [], uptime: 10.5,
									date: date.addingTimeInterval(12.001)))

		let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: folder) }
		let output = try MeasurementExport.writeLogs(session, folder: folder)
		XCTAssertEqual(output.lastPathComponent, "DEMO-MagicPowerMeter-2023-11-14T22-13-20Z-\(session.id.uuidString.prefix(8))-raw")
		let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
		XCTAssertEqual(files.count, 4)
		for number in 1...2 {
			let stem = "DEMO-condition-1-iteration-1-attempt-\(number)"
			let raw = try Data(contentsOf: output.appendingPathComponent(stem + ".txt"))
			XCTAssertEqual(raw, number == 1 ? first + second : Data([1, 2]))
			let chunks: [[String: Any]] = number == 1 ? [
				["offset": 0, "bytes": 3, "elapsed_seconds": 0.25, "received_at": "2023-11-14T22:13:20Z"],
				["offset": 3, "bytes": 9, "elapsed_seconds": 1.0, "received_at": "2023-11-14T22:13:21Z"]
			] : [
				["offset": 0, "bytes": 2, "elapsed_seconds": 0.125, "received_at": "2023-11-14T22:13:31Z"],
				["offset": 2, "bytes": 0, "elapsed_seconds": 0.5, "received_at": "2023-11-14T22:13:32Z"]
			]
			let expected: [String: Any] = [
				"source": MeasurementSource.demo.rawValue,
				"connection": number == 1 ? "first connection" : "second connection",
				"session_id": session.id.uuidString, "incomplete_result": true,
				"condition": session.conditions[0].name, "iteration": 1, "attempt": number,
				"complete": false, "included_in_calculations": false,
				"started_at": number == 1 ? "2023-11-14T22:13:20Z" : "2023-11-14T22:13:30Z",
				"ended_at": number == 1 ? "2023-11-14T22:13:22Z" : "",
				"duration_seconds": number == 1 ? 1.75 : 0.5, "target_seconds": 3.0,
				"stop_detected_after_seconds": number == 1 ? 1.75 : 0.5,
				"valid_samples": number == 1 ? 1 : 0, "warnings": [String](),
				"stop_reason": number == 1 ? "retry requested" : "Идёт запись", "chunks": chunks
			]
			let expectedData = try JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys])
			XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(stem + ".json")), expectedData)
		}
		XCTAssertEqual(try MeasurementExport.writeLogs(session, folder: folder), output)
	}
}
