import SwiftUI

struct MeterPalette {
	let page: Color
	let surface: Color
	let raised: Color
	let field: Color
	let selection: Color
	let border: Color
	let ink: Color
	let muted: Color
	let accent: Color
	let onAccent: Color
	let warning: Color
	let error: Color

	init(colorScheme: ColorScheme) {
		if colorScheme == .dark {
			page = Color(hex: 0x0b1424)
			surface = Color(hex: 0x142338)
			raised = Color(hex: 0x203653)
			field = Color(hex: 0x0e1c30)
			selection = Color(hex: 0x1a3657)
			border = Color(hex: 0x59799f)
			ink = Color(hex: 0xedf6ff)
			muted = Color(hex: 0xb5c8de)
			accent = Color(hex: 0x79d0ff)
			onAccent = Color(hex: 0x062641)
			warning = Color(hex: 0xffd08a)
			error = Color(hex: 0xffb4b4)
		} else {
			page = Color(hex: 0xf0f6ff)
			surface = Color(hex: 0xffffff)
			raised = Color(hex: 0xdeebfa)
			field = Color(hex: 0xf3f7ff)
			selection = Color(hex: 0xdcecff)
			border = Color(hex: 0x738eac)
			ink = Color(hex: 0x122c4b)
			muted = Color(hex: 0x4c6582)
			accent = Color(hex: 0x0069b5)
			onAccent = Color(hex: 0xffffff)
			warning = Color(hex: 0x8a4800)
			error = Color(hex: 0xb02038)
		}
	}
}

private struct MeterPaletteKey: EnvironmentKey {
	static let defaultValue = MeterPalette(colorScheme: .dark)
}

extension EnvironmentValues {
	var meterPalette: MeterPalette {
		get { self[MeterPaletteKey.self] }
		set { self[MeterPaletteKey.self] = newValue }
	}
}

extension Color {
	init(hex: UInt32) {
		self.init(red: Double((hex >> 16) & 255) / 255,
				  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
	}
}

private struct MeterAppearance: ViewModifier {
	let colorScheme: ColorScheme

	func body(content: Content) -> some View {
		let palette = MeterPalette(colorScheme: colorScheme)
		content
			.environment(\.meterPalette, palette)
			.environment(\.colorScheme, colorScheme)
			.preferredColorScheme(colorScheme)
			.foregroundStyle(palette.ink)
			.tint(palette.accent)
	}
}

private struct MeterCard: ViewModifier {
	@Environment(\.meterPalette) private var palette
	let background: Color?
	let padding: CGFloat

	func body(content: Content) -> some View {
		content.padding(padding)
			.background(background ?? palette.surface, in: RoundedRectangle(cornerRadius: 11))
			.overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.border, lineWidth: 1))
	}
}

struct MeterPrimaryButtonStyle: ButtonStyle {
	@Environment(\.meterPalette) private var palette
	@Environment(\.isEnabled) private var enabled
	@Environment(\.controlSize) private var controlSize

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.padding(.horizontal, controlSize == .large ? 16 : 12)
			.padding(.vertical, controlSize == .large ? 8 : 5)
			.foregroundStyle(enabled ? palette.onAccent : palette.muted)
			.background(enabled ? palette.accent : palette.raised, in: RoundedRectangle(cornerRadius: 6))
			.opacity(configuration.isPressed ? 0.85 : 1)
	}
}

struct MeterProgressStyle: ProgressViewStyle {
	@Environment(\.meterPalette) private var palette

	func makeBody(configuration: Configuration) -> some View {
		GeometryReader { geometry in
			RoundedRectangle(cornerRadius: 4)
				.fill(palette.raised)
				.overlay(alignment: .leading) {
					RoundedRectangle(cornerRadius: 4).fill(palette.accent)
						.frame(width: geometry.size.width * min(1, max(0, configuration.fractionCompleted ?? 0)))
				}
		}.frame(height: 8)
	}
}

extension View {
	func meterAppearance(_ colorScheme: ColorScheme) -> some View {
		modifier(MeterAppearance(colorScheme: colorScheme))
	}

	func meterCard(background: Color? = nil, padding: CGFloat = 18) -> some View {
		modifier(MeterCard(background: background, padding: padding))
	}
}

struct ThemeToggle: View {
	@Binding var colorScheme: ColorScheme

	func toggle() {
		colorScheme = colorScheme == .dark ? .light : .dark
	}

	var body: some View {
		Button(action: toggle) {
			Label(colorScheme == .dark ? Strings.UI.lightTheme : Strings.UI.darkTheme,
				  systemImage: colorScheme == .dark ? "sun.max" : "moon")
		}
		.accessibilityLabel(colorScheme == .dark ? Strings.UI.switchToLightTheme : Strings.UI.switchToDarkTheme)
		.accessibilityValue(colorScheme == .dark ? Strings.UI.darkTheme : Strings.UI.lightTheme)
		.accessibilityIdentifier("theme-toggle")
	}
}
