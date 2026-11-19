import AppKit
import Observation
import OSLog
import SwiftUI

enum AppearanceFailure: Error {
	case failed(String)
}

@MainActor
@Observable
final class AppearanceSelection {
	var scheme: ColorScheme = .dark
}

private struct AppearanceProbe: View {
	@Environment(\.colorScheme) private var colorScheme
	let report: (ColorScheme) -> Void

	var body: some View {
		Color.clear
			.onAppear { report(colorScheme) }
			.onChange(of: colorScheme) { _, value in report(value) }
	}
}

private struct SwitchingAppearanceView: View {
	let selection: AppearanceSelection
	let report: (ColorScheme) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Menu("Measurements") { Button("Iteration 1") {} }
				.frame(width: 240, height: 32)
			Picker("Iteration", selection: .constant(1)) {
				Text("Iteration 1").tag(1)
				Text("Iteration 2").tag(2)
			}
			.labelsHidden()
			.frame(width: 240, height: 32)
			AppearanceProbe(report: report)
				.frame(height: 0)
		}
		.padding(20)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(MeterPalette(colorScheme: selection.scheme).page)
		.meterAppearance(selection.scheme)
	}
}

final class AppearanceTransport: SensorTransport, Sendable {
	func discover(_ completion: @escaping @Sendable (Result<[String], SerialFailure>) -> Void) {
		completion(.success([]))
	}
	func connect(settings: SerialSettings, demo: Bool, callback: @escaping @Sendable (TransportEvent) -> Void) {
		preconditionFailure("Appearance tests never connect a sensor")
	}
	func disconnect() {}
}

@main
struct AppearanceSmoke {
	@MainActor static func require(_ value: Bool, _ message: String) throws {
		guard value else { throw AppearanceFailure.failed(message) }
	}

	@MainActor static func settle() {
		RunLoop.main.run(until: Date().addingTimeInterval(0.25))
	}

	@MainActor static func toggleTest() throws {
		let selection = AppearanceSelection()
		let binding = Binding(get: { selection.scheme }, set: { selection.scheme = $0 })
		let toggle = ThemeToggle(colorScheme: binding)
		try require(selection.scheme == .dark, "Initial state must be dark")
		toggle.toggle()
		try require(selection.scheme == .light, "Button did not change selection to light")
		toggle.toggle()
		try require(selection.scheme == .dark, "Button did not return selection to dark")
		print("PASS: SwiftUI button's action handler switches its bound selection dark -> light -> dark.")
	}

	@MainActor static func liveAppearanceTest() throws {
		let selection = AppearanceSelection()
		var observed: ColorScheme?
		let host = NSHostingView(rootView: SwitchingAppearanceView(selection: selection) { observed = $0 })
		let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 180),
							  styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = host
		window.orderFront(nil)
		defer { window.orderOut(nil) }
		for scheme in [ColorScheme.dark, .light, .dark, .light] {
			selection.scheme = scheme
			settle()
			host.layoutSubtreeIfNeeded()
			try require(observed == scheme, "Controls retained the previous color-scheme environment")
			let appearance = host.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
			try require(appearance == (scheme == .dark ? .darkAqua : .aqua),
						"Native controls retained the previous appearance")
			let bitmap = try host.bitmapImageRepForCachingDisplay(in: host.bounds).unwrap("Cannot capture controls")
			host.cacheDisplay(in: host.bounds, to: bitmap)
			let scale = Double(bitmap.pixelsWide) / host.bounds.width
			for top in [20, 68] {
				var visibleTextPixels = 0
				for y in Int(Double(top) * scale)..<Int(Double(top + 32) * scale) {
					for x in Int(20 * scale)..<Int(260 * scale) {
						let color = try (bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
							.unwrap("Cannot read control pixels")
						let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
						if scheme == .dark ? brightness > 0.7 : brightness < 0.3 {
							visibleTextPixels += 1
						}
					}
				}
				try require(visibleTextPixels > 100, "\(scheme) menu/picker text has insufficient contrast after switching")
			}
		}
		print("PASS: repeated live theme changes preserve visible menu/picker text and native appearance.")
	}

	@MainActor static func luminance(_ color: Color) throws -> Double {
		let rgb = try NSColor(color).usingColorSpace(.sRGB).unwrap("Cannot resolve palette color")
		func linear(_ value: CGFloat) -> Double {
			let value = Double(value)
			return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
		}
		return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
	}

	@MainActor static func sprintDeletionTest() throws {
		let model = model()
		model.mode = .sprint
		model.sprintConditions[2].name = "Renamed location"
		let original = model.sprintConditions
		let host = NSHostingView(rootView: ContentView(model: model, colorScheme: .constant(.dark)).meterAppearance(.dark))
		let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1120, height: 1100),
							  styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = host
		window.orderFront(nil)
		defer { window.orderOut(nil) }

		func deleteButtons(in view: NSView) -> [NSButton] {
			if let button = view as? NSButton, button.convert(button.bounds, to: host).minX > host.bounds.midX {
				return [button]
			}
			return view.subviews.flatMap { deleteButtons(in: $0) }
				.sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
		}

		for removedCount in 0..<(original.count - 1) {
			settle()
			host.layoutSubtreeIfNeeded()
			let buttons = deleteButtons(in: host)
			try require(buttons.count == model.sprintConditions.count, "Missing location delete buttons")
			let button = try buttons.first.unwrap("Cannot find location delete button")
			try require(button.isEnabled, "Location delete button disabled too early")
			button.performClick(nil)
			settle()
			try require(model.sprintConditions == Array(original.dropFirst(removedCount + 1)),
						"Delete action removed the wrong location or changed other rows")
		}
		let lastButton = try deleteButtons(in: host).first.unwrap("Missing last location delete button")
		try require(!lastButton.isEnabled, "Last location must not be deleted")
		print("PASS: actual sprint delete buttons remove successive rows without conflicting binding accesses.")
	}

	@MainActor static func contrast(_ first: Color, _ second: Color) throws -> Double {
		let a = try luminance(first)
		let b = try luminance(second)
		return (max(a, b) + 0.05) / (min(a, b) + 0.05)
	}

	@MainActor static func contrastTests() throws {
		for scheme in [ColorScheme.dark, .light] {
			let palette = MeterPalette(colorScheme: scheme)
			for text in [palette.ink, palette.muted, palette.accent, palette.warning, palette.error] {
				for background in [palette.page, palette.surface, palette.raised, palette.field, palette.selection] {
					try require(contrast(text, background) >= 4.5, "\(scheme) text contrast below 4.5:1")
				}
			}
			try require(contrast(palette.onAccent, palette.accent) >= 4.5, "\(scheme) prominent-button contrast below 4.5:1")
			for background in [palette.page, palette.surface, palette.field] {
				try require(contrast(palette.border, background) >= 3, "\(scheme) control-border contrast below 3:1")
			}
		}
		print("PASS: both palettes meet 4.5:1 text/button and 3:1 control-boundary contrast gates.")
	}

	@MainActor static func clockTests() throws {
		for (value, expected): (TimeInterval, String) in [
			(0, "0:00"), (9, "0:09"), (59, "0:59"), (60, "1:00"),
			(61, "1:01"), (180, "3:00"), (61.9, "1:01"), (-9, "0:00"),
			(.infinity, "—"), (.nan, "—"), (.greatestFiniteMagnitude, "—")
		] {
			try require(clockText(value) == expected, "Clock \(value): expected \(expected), got \(clockText(value))")
		}
		let large = clockText(Double(Int.max))
		try require(large.hasSuffix(":08") && !large.contains(" "), "Large finite clock lost m:ss format")
		print("PASS: production m:ss formatter preserves second padding, guards and large values.")
	}

	@MainActor static func scrollViews(in view: NSView) -> [NSScrollView] {
		(view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
	}

	@MainActor static func resultsLayoutTest() throws {
		let cases: [(MeasurementMode, Bool)] = [(.single, false), (.comparison, false), (.sprint, false), (.sprint, true)]
		for scheme in [ColorScheme.dark, .light] {
			let palette = MeterPalette(colorScheme: scheme)
			for (mode, large) in cases {
				let conditions = large ? (1...20).map { Condition(name: "Локация \($0)", iterations: 50) } : mode.defaultConditions
				var session = MeasurementSession(mode: mode, conditions: conditions, duration: 180, timeout: 8,
												 source: .demo, connectionDescription: "DEMO")
				session.finalize(uptime: 0, date: Date())
				for size in [NSSize(width: 900, height: 360), NSSize(width: 1600, height: 700)] {
					let host = NSHostingView(rootView: ResultsView(session: session).meterAppearance(scheme)
						.overlay(alignment: .topLeading) {
							HStack(spacing: 0) {
								palette.raised.frame(width: 4, height: 4)
								palette.selection.frame(width: 4, height: 4)
							}
						})
					let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: size),
										  styleMask: [.borderless], backing: .buffered, defer: false)
					window.contentView = host
					window.orderFront(nil)
					defer { window.orderOut(nil) }
					settle()
					host.layoutSubtreeIfNeeded()
					let label = "\(scheme) \(mode) \(size) large=\(large)"
					let scroll = try scrollViews(in: host).first.unwrap("\(label): missing results scroll view")
					let document = try scroll.documentView.unwrap("\(label): missing table content")
					let viewport = scroll.contentView.bounds.size
					try require(document.bounds.width >= viewport.width - 1 && document.bounds.height >= viewport.height - 1,
								"\(label): table does not fill the available area")
					if large {
						try require(document.bounds.width > viewport.width && document.bounds.height > viewport.height,
									"\(label): large tables must remain scrollable in both directions")
						continue
					}
					try require(document.bounds.width <= viewport.width + 1 && document.bounds.height <= viewport.height + 1,
								"\(label): default table unexpectedly needs scrolling")
					let bitmap = try host.bitmapImageRepForCachingDisplay(in: host.bounds).unwrap("Cannot capture results")
					host.cacheDisplay(in: host.bounds, to: bitmap)
					let rect = scroll.contentView.convert(scroll.contentView.bounds, to: host)
					let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
					let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
					for (x, y, referenceX): (CGFloat, CGFloat, CGFloat) in [
						(rect.minX + 2, top + 8, 2),
						(rect.minX + 2, top + 80, 2),
						(rect.maxX - 2, top + 8, 2),
						(rect.minX + 2, top + rect.height - 2, 6),
						(rect.maxX - 2, top + rect.height - 2, 6)
					] {
						let actual = try (bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
							.unwrap("Cannot read table pixels")
						// Compare rendered swatches so display color profiles do not affect the geometry checks.
						let expected = try (bitmap.colorAt(x: Int(referenceX * scale), y: Int(2 * scale))?.usingColorSpace(.sRGB))
							.unwrap("Cannot read table reference color")
						try require(abs(actual.redComponent - expected.redComponent) < 0.02
									&& abs(actual.greenComponent - expected.greenComponent) < 0.02
									&& abs(actual.blueComponent - expected.blueComponent) < 0.02,
									"\(label): table has empty margins or an uneven header at \(x), \(y): \(actual) instead of \(expected)")
					}
				}
			}
		}
		print("PASS: result tables fill compact and enlarged views, headers span the first column, and large tables stay scrollable.")
	}

	@MainActor static func compactLayoutTest() throws {
		let size = NSSize(width: 1232, height: 800)
		let windowFrame = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: size),
											styleMask: [.titled, .closable, .resizable])
		try require(windowFrame.height <= 850, "Window including the title bar must fit within 850 points")
		for scheme in [ColorScheme.dark, .light] {
			for mode in [MeasurementMode.comparison, .sprint] {
				let fixture = try recordedSession(mode: mode)
				for state in ["setup", "ready", "recording", "messages", "warnings", "retry", "empty", "charts", "table", "large-plan"] {
					let model = model()
					model.mode = mode
					model.demo = true
					model.connected = true
					model.connectedPort = "/dev/cu.usbserial-130"
					model.connectionStatus = Strings.Connection.sensorReady
					if state != "setup" {
						model.session = fixture
						model.selected = fixture.attempts.last?.key
						model.history = [fixture]
						if state == "recording" {
							let key = IterationKey(conditionID: fixture.conditions[0].id, number: 3)
							try model.session?.start(key, uptime: 1000, date: Date())
							model.selected = key
						}
						if state == "messages" {
							model.error = "Тестовая ошибка подключения — показания не потеряны."
							model.notice = "Тестовое предупреждение: неполная попытка исключена из расчётов."
						}
						if state == "warnings" {
							model.selectedAttemptID = fixture.attempts[0].id
						}
						if state == "retry" {
							let key = fixture.attempts[0].key
							try model.session?.retry(key, uptime: 1000, date: Date())
							model.selected = key
						}
						if state == "empty" {
							model.selected = IterationKey(conditionID: fixture.conditions[0].id, number: 3)
						}
						if state == "charts" || state == "table" {
							model.session?.finalize(uptime: 800, date: Date())
						}
						if state == "large-plan" {
							let conditions = (1...20).map { Condition(name: "Локация \($0)", iterations: 50) }
							model.session = MeasurementSession(mode: mode, conditions: conditions, duration: 180,
															  timeout: 8, source: .demo, connectionDescription: "DEMO")
							model.selected = IterationKey(conditionID: conditions[0].id, number: 1)
						}
					}
					let host = NSHostingView(rootView: ContentView(model: model, colorScheme: .constant(scheme),
																  resultsTab: state == "table" ? .table : .charts)
						.meterAppearance(scheme))
					let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: size),
										  styleMask: [.borderless], backing: .buffered, defer: false)
					window.contentView = host
					window.orderFront(nil)
					defer { window.orderOut(nil) }
					settle()
					host.layoutSubtreeIfNeeded()
					let label = "\(scheme) \(mode) \(state)"
					try require(host.bounds.size == size, "\(label): window content resized beyond the target size")
					try require(host.fittingSize.height <= size.height + 1,
								"\(label): minimum height \(host.fittingSize.height) exceeds \(size.height)")
					var sidebarOverflows = false
					for scroll in scrollViews(in: host) {
						let frame = scroll.convert(scroll.bounds, to: host)
						try require(host.bounds.insetBy(dx: -1, dy: -1).contains(frame),
									"\(label): scrolling region outside the window")
						if let document = scroll.documentView {
							let overflows = document.bounds.height > scroll.contentView.bounds.height + 1
							if state == "large-plan", frame.maxX < 340 {
								sidebarOverflows = sidebarOverflows || overflows
							} else {
								try require(!overflows,
											"\(label): content needs vertical scrolling (\(document.bounds.height) > \(scroll.contentView.bounds.height))")
							}
							if state == "table" {
								try require(document.bounds.width <= scroll.contentView.bounds.width + 1,
											"\(label): default result columns require horizontal scrolling")
							}
						}
					}
					if state == "large-plan" {
						try require(sidebarOverflows, "\(label): large plans must remain scrollable within the sidebar")
					}
				}
			}
		}
		print("PASS: setup, recording, messages, charts and default iteration plans fit a 1232 x 800 window without vertical scrolling.")
	}

	@MainActor static func snapshot<V: View>(_ view: V, scheme: ColorScheme, size: NSSize, output: URL) throws {
		let beganAt = Date()
		let host = NSHostingView(rootView: view.meterAppearance(scheme))
		let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: size),
							  styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = host
		window.orderFront(nil)
		defer { window.orderOut(nil) }
		settle()
		host.layoutSubtreeIfNeeded()
		if size == NSSize(width: 1232, height: 800) {
			try require(host.bounds.size == size, "\(output.lastPathComponent): preview resized from \(size) to \(host.bounds.size)")
		}
		let bitmap = try host.bitmapImageRepForCachingDisplay(in: host.bounds).unwrap("Cannot capture the owned preview view")
		host.cacheDisplay(in: host.bounds, to: bitmap)
		let png = try bitmap.representation(using: .png, properties: [:]).unwrap("Cannot encode preview")
		try png.write(to: output)
		let store = try OSLogStore(scope: .currentProcessIdentifier)
		let entries = try store.getEntries(at: store.position(date: beganAt))
		let formattingErrors = entries.compactMap { $0 as? OSLogEntryLog }.filter {
			$0.subsystem == "com.apple.Foundation" && $0.composedMessage.contains("Provided argument types")
		}
		try require(formattingErrors.isEmpty, "\(output.lastPathComponent): \(formattingErrors.first?.composedMessage ?? "")")
		print("PREVIEW: \(output.path)")
	}

	@MainActor static func model() -> MeterModel {
		MeterModel(transport: AppearanceTransport(), exporter: FileMeasurementExporter(),
				   exportFolder: ExportFolder(picker: { nil }))
	}

	@MainActor static func recordedSession(mode: MeasurementMode = .comparison) throws -> MeasurementSession {
		let date = Date(timeIntervalSince1970: 1_700_000_000)
		let conditions = mode == .sprint ? mode.defaultConditions
			: [Condition(name: "База", iterations: 3), Condition(name: "Новое условие", iterations: 3)]
		var session = MeasurementSession(mode: mode, conditions: conditions, duration: 180, timeout: 8,
										 source: .demo, connectionDescription: "DEMO", createdAt: date)
		for (condition, number, count) in [(0, 1, 180), (0, 2, 40), (1, 1, 180)] {
			let start = Double(session.attempts.count * 200)
			try session.start(IterationKey(conditionID: conditions[condition].id, number: number), uptime: start, date: date)
			session.receive(SensorBatch(raw: Data("count;voltage_V;current_mA;power_W\n".utf8),
									   lines: [TimedLine(value: .header, beganAt: start)], uptime: start, date: date))
			for second in 0..<count {
				let power = second == 90 ? 17 : 5 + sin(Double(second) / 12) + Double(condition)
				let reading = SensorReading(count: UInt64(second), voltage: 5, current: 1000, power: power)
				session.receive(SensorBatch(raw: Data("\(second);5;1000;\(power)\n".utf8),
										   lines: [TimedLine(value: .reading(reading), beganAt: start + Double(second))],
										   uptime: start + Double(second), date: date))
			}
			session.stop(uptime: start + Double(count), date: date)
		}
		let key = IterationKey(conditionID: conditions[0].id, number: 1)
		try session.retry(key, uptime: 600, date: date)
		for second in 0..<180 {
			let now = 600 + Double(second)
			session.receive(SensorBatch(raw: Data("\(second);5;1000;8\n".utf8),
									   lines: [TimedLine(value: .reading(SensorReading(count: UInt64(second), voltage: 5, current: 1000, power: 8)),
														 beganAt: now)], uptime: now, date: date))
		}
		session.tick(uptime: 780, date: date)
		try session.rename(mode == .sprint ? "Спринт 42" : "Сравнение сборок")
		return session
	}

	@MainActor static func previews(folder: URL) throws {
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let windowSize = NSSize(width: 1232, height: 800)
		for scheme in [ColorScheme.dark, .light] {
			let name = scheme == .dark ? "dark" : "light"
			let model = model()
			try snapshot(ContentView(model: model, colorScheme: .constant(scheme)), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-startup.png"))
			model.mode = .comparison
			try snapshot(ContentView(model: model, colorScheme: .constant(scheme)), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-setup.png"))
			model.demo = true
			model.connected = true
			model.connectedPort = "Демонстрационный источник"
			model.connectionStatus = "Демонстрация · не реальные измерения"
			model.session = try recordedSession()
			model.selected = model.session?.attempts.last?.key
			model.error = "Тестовая ошибка подключения — показания не потеряны."
			model.notice = "Тестовое предупреждение: неполная попытка исключена из расчётов."
			try snapshot(ContentView(model: model, colorScheme: .constant(scheme)), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-chart.png"))
			try snapshot(PortSettingsView(model: model), scheme: scheme, size: NSSize(width: 620, height: 720),
						 output: folder.appendingPathComponent("\(name)-settings.png"))
			let recording = Self.model()
			recording.mode = .comparison
			recording.demo = true
			recording.connected = true
			recording.connectedPort = model.connectedPort
			recording.connectionStatus = model.connectionStatus
			recording.session = model.session
			let recordingKey = IterationKey(conditionID: try recording.session.unwrap("Missing recording preview").conditions[0].id, number: 3)
			try recording.session?.start(recordingKey, uptime: 1000, date: Date())
			recording.selected = recordingKey
			try snapshot(ContentView(model: recording, colorScheme: .constant(scheme)), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-recording.png"))
			model.session?.finalize(uptime: 800, date: Date())
			model.pendingWrites = 1
			try snapshot(ContentView(model: model, colorScheme: .constant(scheme), resultsTab: .table), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-results.png"))
			model.pendingWrites = 0
			model.error = nil
			model.notice = nil
			try snapshot(ContentView(model: model, colorScheme: .constant(scheme), resultsTab: .table), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-comparison-table.png"))
			for (label, condition, number) in [("complete", 0, 1), ("incomplete", 0, 2), ("empty", 1, 3)] {
				let id = try model.session.unwrap("Missing result preview").conditions[condition].id
				model.select(IterationKey(conditionID: id, number: number))
				try snapshot(ContentView(model: model, colorScheme: .constant(scheme), resultsTab: .charts), scheme: scheme,
							 size: windowSize, output: folder.appendingPathComponent("\(name)-result-chart-\(label).png"))
			}
			model.select(try model.session.unwrap("Missing retry preview").attempts[0].key)
			model.selectedAttemptID = model.session?.attempts[0].id
			try snapshot(ContentView(model: model, colorScheme: .constant(scheme), resultsTab: .charts), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-result-chart-superseded.png"))
			try snapshot(SessionNameView(model: model, editing: true).padding(24).background(MeterPalette(colorScheme: scheme).page),
						 scheme: scheme, size: NSSize(width: 1000, height: 100), output: folder.appendingPathComponent("\(name)-rename.png"))
			let retrying = Self.model()
			retrying.mode = .comparison
			retrying.demo = true
			retrying.connected = true
			retrying.connectedPort = model.connectedPort
			retrying.connectionStatus = model.connectionStatus
			retrying.session = model.session
			let key = try retrying.session.unwrap("Missing finalized retry").attempts[0].key
			try retrying.session?.retry(key, uptime: 1000, date: Date())
			retrying.selected = key
			try snapshot(ContentView(model: retrying, colorScheme: .constant(scheme)), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-remeasurement.png"))
			let sprint = Self.model()
			sprint.mode = .sprint
			sprint.demo = true
			sprint.connected = true
			sprint.connectedPort = model.connectedPort
			sprint.connectionStatus = model.connectionStatus
			try snapshot(ContentView(model: sprint, colorScheme: .constant(scheme)), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-sprint-setup.png"))
			sprint.session = try recordedSession(mode: .sprint)
			sprint.selected = sprint.session?.attempts.last?.key
			try snapshot(ContentView(model: sprint, colorScheme: .constant(scheme)), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-sprint-measurement.png"))
			sprint.session?.finalize(uptime: 800, date: Date())
			sprint.selected = sprint.session?.attempts.last?.key
			try snapshot(ContentView(model: sprint, colorScheme: .constant(scheme), resultsTab: .table), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-sprint-table.png"))
			try snapshot(ContentView(model: sprint, colorScheme: .constant(scheme), resultsTab: .charts), scheme: scheme,
						 size: windowSize, output: folder.appendingPathComponent("\(name)-sprint-chart.png"))
		}
	}

	@MainActor static func main() {
		_ = NSApplication.shared
		NSApp.setActivationPolicy(.accessory)
		NSApp.finishLaunching()
		do {
			try toggleTest()
			try liveAppearanceTest()
			try sprintDeletionTest()
			try contrastTests()
			try clockTests()
			try resultsLayoutTest()
			try compactLayoutTest()
			if CommandLine.arguments.count > 1 {
				try require(CommandLine.arguments.count == 3, "Usage: appearance-smoke [output-folder built-app-bundle]")
				let bundle = try Bundle(path: CommandLine.arguments[2]).unwrap("Cannot load the built app bundle")
				let iconName = try (bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String).unwrap("App bundle has no icon name")
				NSApp.applicationIconImage = try bundle.image(forResource: iconName).unwrap("Cannot load the compiled app icon")
				try previews(folder: URL(fileURLWithPath: CommandLine.arguments[1]))
			}
			print("PASS: appearance smoke; no serial sensor opened.")
		} catch {
			fputs("FAIL: \(error)\n", stderr)
			exit(1)
		}
	}
}

private extension Optional {
	func unwrap(_ message: String) throws -> Wrapped {
		guard let self else { throw AppearanceFailure.failed(message) }
		return self
	}
}
