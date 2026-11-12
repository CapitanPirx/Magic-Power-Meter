import AppKit
import SwiftUI

@main @MainActor struct MagicPowerMeterApp: App {
	@State private var model = MeterModel(
		transport: SerialTransport(),
		exporter: FileMeasurementExporter(),
		exportFolder: ExportFolder(picker: {
			let panel = NSOpenPanel()
			panel.canChooseDirectories = true
			panel.canChooseFiles = false
			panel.canCreateDirectories = true
			panel.prompt = Strings.Export.chooseFolder
			panel.message = Strings.Export.folderMessage
			return panel.runModal() == .OK ? panel.url : nil
		})
	)

	var body: some Scene {
		Window(Strings.Common.appName, id: "meter") {
			ContentView(model: model)
				.preferredColorScheme(.dark)
		}
		.defaultSize(width: 1060, height: 1000)
	}
}
