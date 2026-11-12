import Foundation

struct ResultRow: Identifiable {
    let id: Int
    let label: String
    let values: [Double?]
}

enum MeasurementExport {
    static func rows(_ session: MeasurementSession) -> [ResultRow] {
        let maxIterations = session.conditions.map(\.iterations).max() ?? 0
        var rows = (0..<maxIterations).map { offset in
            ResultRow(id: offset, label: "\(offset + 1)", values: session.conditions.map {
                session.completed(IterationKey(conditionID: $0.id, number: offset + 1))?.mean
            })
        }
        rows.append(ResultRow(id: maxIterations, label: "Среднее", values: session.conditions.map {
            session.mean(conditionID: $0.id)
        }))
        return rows
    }

    static func csv(_ session: MeasurementSession) -> Data {
        var header = ["Итерация"]
        for (index, condition) in session.conditions.enumerated() {
            header.append("\(condition.name), Вт")
            if index > 0 {
                header += ["\(condition.name): Δ к базе, Вт", "\(condition.name): Δ к базе, %"]
            }
        }
        header += ["Результат", "Источник", "Комплектность"]
        var records = [header]
        for row in rows(session) {
            var record = [row.label]
            let base = row.values.first ?? nil
            for (index, value) in row.values.enumerated() {
                record.append(value.map(Numeric.text) ?? "")
                if index > 0 {
                    record += [
                        Numeric.delta(value, base: base).map(Numeric.text) ?? "",
                        Numeric.percent(value, base: base).map(Numeric.text) ?? ""
                    ]
                }
            }
            record += [session.incomplete ? "Неполный результат" : "Полный результат",
                       session.source.rawValue, "\(session.completedIterations)/\(session.totalIterations)"]
            records.append(record)
        }
        let text = "\u{FEFF}" + records.map { $0.map(escape).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
        return Data(text.utf8)
    }

    static func escape(_ value: String) -> String {
        if value.contains(where: { ";\"\r\n".contains($0) }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    static func filePrefix(_ session: MeasurementSession) -> String {
        let date = ISO8601DateFormatter().string(from: session.createdAt).replacingOccurrences(of: ":", with: "-")
        return "\(session.source == .demo ? "DEMO-" : "")MagicPowerMeter-\(date)-\(session.id.uuidString.prefix(8))"
    }

    static func writeResult(_ session: MeasurementSession, folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(filePrefix(session) + ".csv")
        try csv(session).write(to: url, options: .atomic)
        return url
    }

    static func writeLogs(_ session: MeasurementSession, folder: URL, key: IterationKey? = nil) throws -> URL {
        let directory = folder.appendingPathComponent(filePrefix(session) + "-raw", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dateFormatter = ISO8601DateFormatter()
        for attempt in session.attempts where key == nil || attempt.key == key {
            guard let conditionIndex = session.conditions.firstIndex(where: { $0.id == attempt.key.conditionID }) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let condition = session.conditions[conditionIndex]
            let stem = "\(session.source == .demo ? "DEMO-" : "")condition-\(conditionIndex + 1)-iteration-\(attempt.key.number)-attempt-\(attempt.number)"
            var raw = Data()
            var offsets: [[String: Any]] = []
            for chunk in attempt.chunks {
                offsets.append(["offset": raw.count, "bytes": chunk.data.count,
                                "elapsed_seconds": chunk.elapsed,
                                "received_at": dateFormatter.string(from: chunk.date)])
                raw.append(chunk.data)
            }
            try raw.write(to: directory.appendingPathComponent(stem + ".txt"), options: .atomic)
            let metadata: [String: Any] = [
                "source": session.source.rawValue, "connection": attempt.connectionDescription,
                "session_id": session.id.uuidString, "incomplete_result": session.incomplete,
                "condition": condition.name, "iteration": attempt.key.number, "attempt": attempt.number,
                "complete": attempt.complete, "included_in_calculations": attempt.complete,
                "started_at": dateFormatter.string(from: attempt.startedAt),
                "ended_at": attempt.endedAt.map { dateFormatter.string(from: $0) } ?? "",
                "duration_seconds": attempt.elapsed, "target_seconds": session.duration,
                "stop_detected_after_seconds": attempt.stoppedAfter ?? attempt.elapsed,
                "valid_samples": attempt.samples.count, "warnings": attempt.warnings,
                "stop_reason": attempt.stopReason ?? "Идёт запись", "chunks": offsets
            ]
            let json = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: directory.appendingPathComponent(stem + ".json"), options: .atomic)
        }
        return directory
    }
}
