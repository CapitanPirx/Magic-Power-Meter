import Foundation
import Observation

@MainActor @Observable
final class MeterModel {
	var settings = SerialSettings()
	var ports: [String] = []
	var demo = false
	var connected = false
	var preparing = false
	var connectedPort = Strings.Connection.notConnected
	var connectionStatus = Strings.Connection.selectSource
	var preview = ""
	var error: String?
	var notice: String?
	var mode: MeasurementMode = .single
	var conditions = MeasurementMode.comparison.defaultConditions
	let sprintConditions = MeasurementMode.sprint.defaultConditions
	var minutes = 3
	var seconds = 0
	var session: MeasurementSession?
	var history: [MeasurementSession] = []
	var selected: IterationKey?
	var selectedAttemptID: UUID?
	var saveRaw = true
	var folder: URL? {
		get { exportFolder.url }
		set { exportFolder.url = newValue }
	}
	var pendingWrites = 0
	var generatedCSV: Data?
	private let transport: any SensorTransport
	private let exporter: any MeasurementExporting
	private let exportFolder: ExportFolder
	private var timer: Timer?
	private var generation = UUID()
	private var measurementActivity: NSObjectProtocol?

	var recording: Bool { session?.active != nil }
	var duration: TimeInterval { Double(minutes) * 60 + Double(seconds) }
	var plannedConditions: [Condition] {
		switch mode {
		case .single: return MeasurementMode.single.defaultConditions
		case .comparison: return conditions
		case .sprint: return sprintConditions
		}
	}
	var viewedAttempt: MeasurementAttempt? {
		guard let session, let selected else { return nil }
		if let selectedAttemptID {
			return session.attempts.first { $0.id == selectedAttemptID }
		}
		if session.active?.key == selected { return session.active }
		return session.completed(selected) ?? session.latest(selected)
	}
	private var readyForRecording: Bool {
		connected && !preparing && !recording && session?.source == (demo ? .demo : .serial)
	}
	var startTarget: IterationKey? {
		guard readyForRecording else { return nil }
		return session?.nextStartKey(selected: selected)
	}
	var canStart: Bool { startTarget != nil }
	var canRetry: Bool {
		guard readyForRecording, let session, session.mode != .single, let selected else { return false }
		return session.latest(selected) != nil
	}
	var selectedName: String {
		guard let selected else { return Strings.Model.noIteration }
		return Strings.Model.selectedIteration(condition: session?.conditions.first { $0.id == selected.conditionID }?.name ?? "", number: selected.number)
	}

	init(transport: any SensorTransport, exporter: any MeasurementExporting, exportFolder: ExportFolder) {
		self.transport = transport
		self.exporter = exporter
		self.exportFolder = exportFolder
		refreshPorts()
	}

	isolated deinit {
		timer?.invalidate()
		if let measurementActivity { ProcessInfo.processInfo.endActivity(measurementActivity) }
		transport.disconnect()
	}

	func refreshPorts() {
		transport.discover { [weak self] result in
			DispatchQueue.main.async { [weak self] in
				switch result {
				case .success(let ports): self?.ports = ports
				case .failure(let error): self?.error = error.localizedDescription
				}
			}
		}
	}

	func connect() {
		guard !recording else { return }
		error = nil
		connected = false
		preparing = true
		preview = ""
		generation = UUID()
		let token = generation
		transport.connect(settings: settings, demo: demo) { [weak self] event in
			DispatchQueue.main.async { [weak self] in
				guard let self, self.generation == token else { return }
				self.handle(event)
			}
		}
	}

	func disconnect() {
		if recording { stop(reason: Strings.Connection.disconnectedAttempt) }
		generation = UUID()
		transport.disconnect()
		connected = false
		preparing = false
		connectedPort = Strings.Connection.notConnected
		connectionStatus = Strings.Connection.disconnected
	}

	private func handle(_ event: TransportEvent) {
		switch event {
		case .preparing(let message):
			connectionStatus = message
		case .ready(let path):
			connected = true
			preparing = false
			connectedPort = path
			connectionStatus = demo ? Strings.Connection.demoReady : Strings.Connection.sensorReady
		case .batch(let batch):
			preview += String(decoding: batch.raw, as: UTF8.self)
			preview = String(preview.suffix(1800))
			let wasRecording = recording
			session?.receive(batch)
			if wasRecording && !recording { iterationStopped() }
		case .failure(let message):
			connected = false
			preparing = false
			connectionStatus = Strings.Connection.failed
			error = message
			if recording { stop(reason: Strings.Connection.excluded(message)) }
		}
	}

	func createSession() {
		guard session == nil else {
			error = Strings.Model.existingSession
			return
		}
		guard duration > 0, (0...59).contains(seconds), minutes >= 0 else {
			error = Strings.Model.invalidDuration
			return
		}
		let plan = plannedConditions
		guard plan.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...50).contains($0.iterations) }),
			  !plan.isEmpty, mode != .comparison || plan.count >= 2 else {
			error = Strings.Model.invalidConditions
			return
		}
		session = MeasurementSession(mode: mode,
									 conditions: plan, duration: duration, timeout: settings.timeout,
									 source: demo ? .demo : .serial,
									 connectionDescription: Strings.Connection.description(port: connectedPort, settings: settings.summary))
		selected = IterationKey(conditionID: plan[0].id, number: 1)
		selectedAttemptID = nil
		generatedCSV = nil
		error = nil
		notice = nil
	}

	func start() {
		guard let target = startTarget else { return }
		begin(target, retry: false)
	}

	func retry() {
		guard canRetry, let selected else {
			error = Strings.Model.retryUnavailable
			return
		}
		begin(selected, retry: true)
	}

	private func begin(_ key: IterationKey, retry: Bool) {
		do {
			let connection = Strings.Connection.description(port: connectedPort, settings: settings.summary)
			if retry {
				try session?.retry(key, uptime: MonotonicTime.now, date: Date(), connectionDescription: connection)
			} else {
				try session?.start(key, uptime: MonotonicTime.now, date: Date(), connectionDescription: connection)
			}
			measurementActivity = ProcessInfo.processInfo.beginActivity(
				options: [.userInitiated, .idleSystemSleepDisabled], reason: Strings.Model.activity)
			selected = key
			selectedAttemptID = nil
			generatedCSV = nil
			notice = nil
			error = nil
			timer?.invalidate()
			let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
				Task { @MainActor [weak self] in self?.tick() }
			}
			self.timer = timer
			RunLoop.main.add(timer, forMode: .common)
		} catch { self.error = error.localizedDescription }
	}

	private func tick() {
		guard recording else { return }
		session?.tick(uptime: MonotonicTime.now, date: Date())
		if !recording { iterationStopped() }
	}

	func stop(reason: String = Strings.Measurement.manuallyStopped) {
		session?.stop(uptime: MonotonicTime.now, date: Date(), reason: reason)
		iterationStopped()
	}

	private func iterationStopped() {
		timer?.invalidate()
		timer = nil
		endActivity()
		if let last = session?.attempts.last, !last.complete {
			notice = session?.completed(last.key) != nil
				? Strings.Model.previousResultKept(last.stopReason ?? "")
				: Strings.Model.incompleteAttempt(last.stopReason ?? "")
		} else {
			notice = session?.finalized == true ? Strings.Model.retryFinished : Strings.Model.iterationFinished
		}
		if let session, session.finalized {
			updateResult(session, announce: false)
		} else if saveRaw, let session, folder != nil {
			write(session: session, contents: .logs(nil))
		}
	}

	func select(_ key: IterationKey) {
		guard !recording else { return }
		selected = key
		selectedAttemptID = nil
	}

	func nextIteration() {
		guard let session else { return }
		if let key = session.nextStartKey(selected: nil) {
			select(key)
			return
		}
		notice = Strings.Model.allIterationsRecorded
	}

	func finalize() {
		guard session != nil else { return }
		session?.finalize(uptime: MonotonicTime.now, date: Date())
		timer?.invalidate()
		timer = nil
		endActivity()
		guard let session else { return }
		updateResult(session)
	}

	private func updateResult(_ session: MeasurementSession, announce: Bool = true) {
		generatedCSV = MeasurementExport.csv(session)
		if announce { notice = Strings.Export.csvGenerated(needsFolder: folder == nil) }
		if folder != nil { write(session: session, contents: saveRaw ? .resultAndLogs : .result) }
	}

	@discardableResult
	func renameSession(_ name: String) -> Bool {
		guard session != nil else {
			error = Strings.Measurement.invalidState
			return false
		}
		do {
			try session?.rename(name)
			error = nil
			return true
		} catch {
			self.error = error.localizedDescription
			return false
		}
	}

	func newSession() {
		guard !recording, session?.finalized != false else { return }
		if let session { history.append(session) }
		session = nil
		selected = nil
		selectedAttemptID = nil
		generatedCSV = nil
		notice = nil
	}

	func showHistory(_ id: UUID) {
		guard !recording, let index = history.firstIndex(where: { $0.id == id }) else { return }
		let previous = session
		session = history.remove(at: index)
		if let previous { history.append(previous) }
		if let session { mode = session.mode }
		if let first = session?.conditions.first {
			selected = IterationKey(conditionID: first.id, number: 1)
		}
		selectedAttemptID = nil
		generatedCSV = session?.finalized == true ? session.map(MeasurementExport.csv) : nil
	}

	func chooseFolder() {
		guard exportFolder.choose() else { return }
		notice = Strings.Export.folderSelected
	}

	func exportResult() {
		guard let session, session.finalized else { return }
		if folder == nil { chooseFolder() }
		guard folder != nil else { return }
		error = nil
		write(session: session, contents: .result)
	}

	func exportLogs(selectedOnly: Bool = false) {
		guard let snapshot = session else { return }
		if selectedOnly && selected == nil { return }
		if folder == nil { chooseFolder() }
		guard folder != nil else { return }
		error = nil
		write(session: snapshot, contents: .logs(selectedOnly ? selected : nil))
	}

	private func endActivity() {
		if let measurementActivity {
			ProcessInfo.processInfo.endActivity(measurementActivity)
			self.measurementActivity = nil
		}
	}

	private func write(session: MeasurementSession, contents: ExportContents) {
		guard let folder else { return }
		let request = ExportRequest(session: session, folder: folder, contents: contents)
		pendingWrites += 1
		exporter.write(request) { result in
			self.pendingWrites -= 1
			switch result {
			case .success(let urls):
				self.notice = Strings.Export.saved(paths: urls.map(\.path))
			case .failure(let error):
				self.error = Strings.Export.failed(error.localizedDescription)
			}
		}
	}
}
