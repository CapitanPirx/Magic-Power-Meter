import Foundation
import Observation

enum ExportContents: Sendable, Equatable {
	case result
	case logs(IterationKey?)
	case resultAndLogs
}

struct ExportRequest: Sendable {
	let session: MeasurementSession
	let folder: URL
	let contents: ExportContents
}

@MainActor
protocol MeasurementExporting: AnyObject {
	func write(_ request: ExportRequest,
			   completion: @escaping @MainActor @Sendable (Result<[URL], Error>) -> Void)
}

@MainActor
final class FileMeasurementExporter: MeasurementExporting {
	private let queue = DispatchQueue(label: "dev.magicpowermeter.export", qos: .utility)

	func write(_ request: ExportRequest,
			   completion: @escaping @MainActor @Sendable (Result<[URL], Error>) -> Void) {
		queue.async {
			do {
				let urls = try Self.writeFiles(request)
				Task { @MainActor in completion(.success(urls)) }
			} catch {
				Task { @MainActor in completion(.failure(error)) }
			}
		}
	}

	private nonisolated static func writeFiles(_ request: ExportRequest) throws -> [URL] {
		switch request.contents {
		case .result:
			return [try MeasurementExport.writeResult(request.session, folder: request.folder)]
		case .logs(let key):
			return [try MeasurementExport.writeLogs(request.session, folder: request.folder, key: key)]
		case .resultAndLogs:
			return [
				try MeasurementExport.writeResult(request.session, folder: request.folder),
				try MeasurementExport.writeLogs(request.session, folder: request.folder)
			]
		}
	}
}

@MainActor @Observable
final class ExportFolder {
	var url: URL? {
		willSet {
			if scoped { url?.stopAccessingSecurityScopedResource() }
		}
		didSet { scoped = url?.startAccessingSecurityScopedResource() ?? false }
	}
	@ObservationIgnored private var scoped = false
	private let picker: @MainActor () -> URL?

	init(picker: @escaping @MainActor () -> URL?) {
		self.picker = picker
	}

	isolated deinit {
		if scoped { url?.stopAccessingSecurityScopedResource() }
	}

	@discardableResult
	func choose() -> Bool {
		guard let selection = picker() else { return false }
		url = selection
		return true
	}
}
