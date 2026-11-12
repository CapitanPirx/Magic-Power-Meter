import AppKit
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
	var comparison = false
	var conditions = [Condition(name: Strings.Common.base, iterations: 3), Condition(name: Strings.Common.condition(1), iterations: 3)]
	var minutes = 3
	var seconds = 0
	var session: MeasurementSession?
	var history: [MeasurementSession] = []
	var selected: IterationKey?
	var selectedAttemptID: UUID?
	var saveRaw = true
	var folder: URL?
	var pendingWrites = 0
	var generatedCSV: Data?
	private let transport = SerialTransport()
	private let exportQueue = DispatchQueue(label: "dev.magicpowermeter.export", qos: .utility)
	private var timer: Timer?
	private var generation = UUID()
	private var folderScoped = false
	private var measurementActivity: NSObjectProtocol?

	var recording: Bool { session?.active != nil }
	var duration: TimeInterval { Double(minutes) * 60 + Double(seconds) }
	var viewedAttempt: MeasurementAttempt? {
		guard let session, let selected else { return nil }
		if let selectedAttemptID {
			return session.attempts.first { $0.id == selectedAttemptID }
		}
		return session.latest(selected)
	}
	var canStart: Bool {
		guard connected, !recording, let session, !session.finalized, let selected else { return false }
		return session.completed(selected) == nil && session.source == (demo ? .demo : .serial)
	}
	var selectedName: String {
		guard let selected else { return Strings.Model.noIteration }
		return Strings.Model.selectedIteration(condition: session?.conditions.first { $0.id == selected.conditionID }?.name ?? "", number: selected.number)
	}

	init() { refreshPorts() }

	isolated deinit {
		timer?.invalidate()
		if let measurementActivity { ProcessInfo.processInfo.endActivity(measurementActivity) }
		if folderScoped { folder?.stopAccessingSecurityScopedResource() }
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
		let plan = comparison ? conditions : [Condition(name: Strings.Common.singleMeasurement, iterations: 1)]
		guard plan.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...50).contains($0.iterations) }),
			  !plan.isEmpty, !comparison || plan.count >= 2 else {
			error = Strings.Model.invalidConditions
			return
		}
		session = MeasurementSession(conditions: plan, duration: duration, timeout: settings.timeout,
									 source: demo ? .demo : .serial,
									 connectionDescription: Strings.Connection.description(port: connectedPort, settings: settings.summary))
		selected = IterationKey(conditionID: plan[0].id, number: 1)
		selectedAttemptID = nil
		generatedCSV = nil
		error = nil
		notice = nil
	}

	func start() {
		guard canStart, let selected else { return }
		do {
			try session?.start(selected, uptime: MonotonicTime.now, date: Date(),
							   connectionDescription: Strings.Connection.description(port: connectedPort, settings: settings.summary))
			measurementActivity = ProcessInfo.processInfo.beginActivity(
				options: [.userInitiated, .idleSystemSleepDisabled], reason: Strings.Model.activity)
			selectedAttemptID = nil
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
			notice = Strings.Model.incompleteAttempt(last.stopReason ?? "")
		} else {
			notice = Strings.Model.iterationFinished
		}
		if saveRaw, let session, folder != nil { write(session: session, result: false, logs: true) }
	}

	func select(_ key: IterationKey) {
		guard !recording else { return }
		selected = key
		selectedAttemptID = nil
	}

	func nextIteration() {
		guard let session else { return }
		for condition in session.conditions {
			for number in 1...condition.iterations {
				let key = IterationKey(conditionID: condition.id, number: number)
				if session.completed(key) == nil {
					select(key)
					return
				}
			}
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
		generatedCSV = MeasurementExport.csv(session)
		notice = Strings.Export.csvGenerated(needsFolder: folder == nil)
		if folder != nil { write(session: session, result: true, logs: saveRaw) }
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
		comparison = (session?.conditions.count ?? 1) > 1
		if let first = session?.conditions.first {
			selected = IterationKey(conditionID: first.id, number: 1)
		}
		selectedAttemptID = nil
		generatedCSV = session?.finalized == true ? session.map(MeasurementExport.csv) : nil
	}

	func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.prompt = Strings.Export.chooseFolder
		panel.message = Strings.Export.folderMessage
		guard panel.runModal() == .OK, let url = panel.url else { return }
		if folderScoped { folder?.stopAccessingSecurityScopedResource() }
		folderScoped = url.startAccessingSecurityScopedResource()
		folder = url
		notice = Strings.Export.folderSelected
	}

	func exportResult() {
		guard let session, session.finalized else { return }
		if folder == nil { chooseFolder() }
		guard folder != nil else { return }
		error = nil
		write(session: session, result: true, logs: false)
	}

	func exportLogs(selectedOnly: Bool = false) {
		guard let snapshot = session else { return }
		if selectedOnly && selected == nil { return }
		if folder == nil { chooseFolder() }
		guard folder != nil else { return }
		error = nil
		write(session: snapshot, result: false, logs: true, key: selectedOnly ? selected : nil)
	}

	private func endActivity() {
		if let measurementActivity {
			ProcessInfo.processInfo.endActivity(measurementActivity)
			self.measurementActivity = nil
		}
	}

	private func write(session: MeasurementSession, result: Bool, logs: Bool, key: IterationKey? = nil) {
		guard let folder else { return }
		pendingWrites += 1
		exportQueue.async {
			do {
				var paths: [String] = []
				if result { paths.append(try MeasurementExport.writeResult(session, folder: folder).path) }
				if logs { paths.append(try MeasurementExport.writeLogs(session, folder: folder, key: key).path) }
				let message = Strings.Export.saved(paths: paths)
				Task { @MainActor in
					self.pendingWrites -= 1
					self.notice = message
				}
			} catch {
				let message = error.localizedDescription
				Task { @MainActor in
					self.pendingWrites -= 1
					self.error = Strings.Export.failed(message)
				}
			}
		}
	}
}
