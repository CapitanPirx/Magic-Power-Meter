import SwiftUI

@main @MainActor struct MagicPowerMeterApp: App {
	@State private var model = MeterModel()

	var body: some Scene {
		Window(Strings.Common.appName, id: "meter") {
			ContentView(model: model)
				.preferredColorScheme(.dark)
		}
		.defaultSize(width: 1060, height: 1000)
	}
}
