import CoreText
import SwiftUI

public extension Color {
    /// Draws an OKLCH token in Display P3 (falls back to sRGB clipping on sRGB displays).
    init(_ c: OKLCH) {
        let p = c.displayP3
        self.init(.displayP3, red: p.r, green: p.g, blue: p.b, opacity: c.alpha)
    }
}

/// Everything a component needs to draw itself in the current Appearance.
public struct ObsidianTheme: Equatable {
    public var appearance: Appearance
    public var palette: SemanticPalette
    public var isDark: Bool

    public init(appearance: Appearance, systemIsDark: Bool = true) {
        self.appearance = appearance
        palette = SemanticPalette.make(appearance, systemIsDark: systemIsDark)
        isDark = appearance.effectiveTheme(systemIsDark: systemIsDark).isDark
    }

    // Semantic colours as SwiftUI Colors.
    public var background: Color { Color(palette.background) }
    public var surface: Color { Color(palette.surface) }
    public var surface2: Color { Color(palette.surface2) }
    public var surface3: Color { Color(palette.surface3) }
    public var border: Color { Color(palette.border) }
    public var text: Color { Color(palette.text) }
    public var textSecondary: Color { Color(palette.textSecondary) }
    public var textMuted: Color { Color(palette.textMuted) }
    public var primary: Color { Color(palette.primary) }
    public var onPrimary: Color { Color(palette.onPrimary) }
    public var success: Color { Color(palette.success) }
    public var warning: Color { Color(palette.warning) }
    public var error: Color { Color(palette.error) }
    public func cue(_ i: Int) -> Color { Color(palette.cues[i % palette.cues.count]) }

    // Density.
    public var compact: Bool { appearance.density == .compact }
    public var pad: CGFloat { compact ? 12 : 18 }
    public var gap: CGFloat { compact ? 8 : 14 }
    /// Touch targets never shrink below 44 pt, even in Compact.
    public var control: CGFloat { compact ? 44 : 52 }
    public var radius: CGFloat { 6 }

    // Type: Geist for UI, Geist Mono (tabular) for every number.
    public func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom(ObsidianFonts.name(mono: false, weight: weight), size: size, relativeTo: .body)
    }
    public func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom(ObsidianFonts.name(mono: true, weight: weight), size: size, relativeTo: .body).monospacedDigit()
    }
}

private struct ObsidianThemeKey: EnvironmentKey {
    static let defaultValue = ObsidianTheme(appearance: Appearance())
}

public extension EnvironmentValues {
    var obsidian: ObsidianTheme {
        get { self[ObsidianThemeKey.self] }
        set { self[ObsidianThemeKey.self] = newValue }
    }
}

/// Registers the bundled Geist fonts (SIL Open Font License) once per process.
public enum ObsidianFonts {
    private static let registered: Bool = {
        let names = ["Geist-Regular", "Geist-Medium", "Geist-SemiBold", "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold"]
        for n in names {
            if let url = Bundle.module.url(forResource: n, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        return true
    }()

    public static func register() { _ = registered }

    static func name(mono: Bool, weight: Font.Weight) -> String {
        let family = mono ? "GeistMono" : "Geist"
        switch weight {
        case .semibold, .bold, .heavy, .black: return "\(family)-SemiBold"
        case .medium: return "\(family)-Medium"
        default: return "\(family)-Regular"
        }
    }
}

/// Small text label in the Obsidian style: Geist Mono, tracked, muted.
public struct Eyebrow: View {
    @Environment(\.obsidian) private var t
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(t.mono(10, .medium))
            .tracking(1.2)
            .foregroundStyle(t.textMuted)
    }
}
