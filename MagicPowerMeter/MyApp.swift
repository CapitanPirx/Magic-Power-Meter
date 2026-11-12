import SwiftUI

@main @MainActor struct MagicPowerMeterApp: App {
	@State private var model = MeterModel()

	var body: some Scene {
		Window("Magic Power Meter", id: "meter") {
			ContentView(model: model)
				.preferredColorScheme(.dark)
		}
		.defaultSize(width: 1060, height: 1000)
	}
}
