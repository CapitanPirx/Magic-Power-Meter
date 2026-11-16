import AppKit
import SwiftUI

enum AppearanceFailure: Error {
	case failed(String)
}

@MainActor
final class AppearanceSelection {
	var scheme: ColorScheme = .dark
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

	@MainActor static func luminance(_ color: Color) throws -> Double {
		let rgb = try NSColor(color).usingColorSpace(.sRGB).unwrap("Cannot resolve palette color")
		func linear(_ value: CGFloat) -> Double {
			let value = Double(value)
			return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
		}
		return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
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

	@MainActor static func snapshot<V: View>(_ view: V, scheme: ColorScheme, size: NSSize, output: URL) throws {
		let host = NSHostingView(rootView: view.meterAppearance(scheme))
		let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: size),
							  styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = host
		window.orderFront(nil)
		defer { window.orderOut(nil) }
		settle()
		host.layoutSubtreeIfNeeded()
		let bitmap = try host.bitmapImageRepForCachingDisplay(in: host.bounds).unwrap("Cannot capture the owned preview view")
		host.cacheDisplay(in: host.bounds, to: bitmap)
		let png = try bitmap.representation(using: .png, properties: [:]).unwrap("Cannot encode preview")
		try png.write(to: output)
		print("PREVIEW: \(output.path)")
	}

	@MainActor static func model() -> MeterModel {
		MeterModel(transport: AppearanceTransport(), exporter: FileMeasurementExporter(),
				   exportFolder: ExportFolder(picker: { nil }))
	}

	@MainActor static func recordedSession() throws -> MeasurementSession {
		let date = Date(timeIntervalSince1970: 1_700_000_000)
		let conditions = [Condition(name: "База", iterations: 3), Condition(name: "Новое условие", iterations: 3)]
		var session = MeasurementSession(conditions: conditions, duration: 180, timeout: 8,
										 source: .demo, connectionDescription: "DEMO", createdAt: date)
		for (condition, number, count) in [(0, 1, 180), (0, 2, 40), (1, 1, 180)] {
			let start = Double(session.attempts.count * 200)
			try session.start(IterationKey(conditionID: conditions[condition].id, number: number), uptime: start, date: date)
			for second in 0..<count {
				let power = second == 90 ? 17 : 5 + sin(Double(second) / 12) + Double(condition)
				let reading = SensorReading(count: UInt64(second), voltage: 5, current: 1000, power: power)
				session.receive(SensorBatch(raw: Data("\(second);5;1000;\(power)\n".utf8),
										   lines: [TimedLine(value: .reading(reading), beganAt: start + Double(second))],
										   uptime: start + Double(second), date: date))
			}
			session.stop(uptime: start + Double(count), date: date)
		}
		return session
	}

	@MainActor static func previews(folder: URL) throws {
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		for scheme in [ColorScheme.dark, .light] {
			let name = scheme == .dark ? "dark" : "light"
			let model = model()
			model.comparison = true
			try snapshot(ContentView(model: model, colorScheme: .constant(scheme)), scheme: scheme,
						 size: NSSize(width: 1120, height: 1100), output: folder.appendingPathComponent("\(name)-setup.png"))
			model.demo = true
			model.connected = true
			model.connectedPort = "Демонстрационный источник"
			model.connectionStatus = "Демонстрация · не реальные измерения"
			model.session = try recordedSession()
			model.selected = model.session?.attempts.last?.key
			model.error = "Тестовая ошибка подключения — показания не потеряны."
			model.notice = "Тестовое предупреждение: неполная попытка исключена из расчётов."
			try snapshot(ContentView(model: model, colorScheme: .constant(scheme)), scheme: scheme,
						 size: NSSize(width: 1120, height: 1780), output: folder.appendingPathComponent("\(name)-chart.png"))
			try snapshot(PortSettingsView(model: model), scheme: scheme, size: NSSize(width: 620, height: 720),
						 output: folder.appendingPathComponent("\(name)-settings.png"))
			let recording = Self.model()
			recording.demo = true
			recording.connected = true
			recording.connectedPort = model.connectedPort
			recording.connectionStatus = model.connectionStatus
			recording.session = model.session
			let recordingKey = IterationKey(conditionID: try recording.session.unwrap("Missing recording preview").conditions[0].id, number: 3)
			try recording.session?.start(recordingKey, uptime: 1000, date: Date())
			recording.selected = recordingKey
			try snapshot(ContentView(model: recording, colorScheme: .constant(scheme)), scheme: scheme,
						 size: NSSize(width: 1120, height: 1780), output: folder.appendingPathComponent("\(name)-recording.png"))
			model.session?.finalize(uptime: 600, date: Date())
			model.pendingWrites = 1
			try snapshot(ContentView(model: model, colorScheme: .constant(scheme)), scheme: scheme,
						 size: NSSize(width: 1120, height: 1780), output: folder.appendingPathComponent("\(name)-results.png"))
		}
	}

	@MainActor static func main() {
		_ = NSApplication.shared
		NSApp.setActivationPolicy(.accessory)
		NSApp.finishLaunching()
		do {
			try toggleTest()
			try contrastTests()
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
