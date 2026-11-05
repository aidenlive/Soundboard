import Foundation

/// The user's Settings › Appearance choices. Obsidian (OLED · Volt · Linear · Spectral) is the default.
public struct Appearance: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable, Identifiable {
        case oled, graphite, daylight
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .oled: "OLED Black"
            case .graphite: "Graphite"
            case .daylight: "Daylight"
            }
        }
        public var isDark: Bool { self != .daylight }
    }

    public enum Accent: String, Codable, CaseIterable, Sendable, Identifiable {
        case volt, signal, ice, ember, violet
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    public enum DeckView: String, Codable, CaseIterable, Sendable, Identifiable {
        case linear, radial, lanes
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    public enum Waveform: String, Codable, CaseIterable, Sendable, Identifiable {
        case spectral, decktint, contrast, accent, mono, custom
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .spectral: "Spectral"
            case .decktint: "Deck tint"
            case .contrast: "High contrast"
            case .accent: "Accent"
            case .mono: "Mono"
            case .custom: "Custom"
            }
        }
        public var subtitle: String {
            switch self {
            case .spectral: "Lows blue · mids orange · highs white"
            case .decktint: "Each deck in its own colour"
            case .contrast: "Colour-blind safe · readable in sunlight"
            case .accent: "Follows your accent colour"
            case .mono: "Neutral, so the grid and cues stand out"
            case .custom: "Pick each band, with guardrails"
            }
        }
    }

    public enum Density: String, Codable, CaseIterable, Sendable, Identifiable {
        case comfortable, compact
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    public var theme: Theme = .oled
    public var accent: Accent = .volt
    public var deckView: DeckView = .linear
    public var waveform: Waveform = .spectral
    public var customWaveform = CustomWaveform()
    public var density: Density = .comfortable
    public var followSystem = false
    public var perControllerLayouts = true

    public init() {}

    /// The theme actually shown, honouring "Follow system light / dark".
    public func effectiveTheme(systemIsDark: Bool) -> Theme {
        guard followSystem else { return theme }
        return systemIsDark ? (theme == .daylight ? .oled : theme) : .daylight
    }
}

/// User-picked waveform band colours, kept legible by guardrails.
public struct CustomWaveform: Codable, Equatable, Sendable {
    public enum Hue: String, Codable, CaseIterable, Sendable, Identifiable {
        case sky, violet, pink, orange, cyan, white
        public var id: String { rawValue }
    }

    public var low: Hue = .pink
    public var mid: Hue = .orange
    public var high: Hue = .white

    public init(low: Hue = .pink, mid: Hue = .orange, high: Hue = .white) {
        self.low = low
        self.mid = mid
        self.high = high
    }

    public struct Resolved: Equatable, Sendable {
        public var low: String   // palette keys, e.g. "pink.600"
        public var mid: String
        public var high: String
        public var notes: [String]
    }

    /// Low uses step 600, Mid 400, High 200 (or white). Adjacent bands must differ by at least
    /// `ObsidianTokens.customMinLightnessGap` in OKLCH lightness: Mid is lifted to 200 first,
    /// then High falls back to white. Every adjustment is reported so the UI can explain it.
    public func resolve() -> Resolved {
        let gap = ObsidianTokens.customMinLightnessGap
        func key(_ hue: Hue, _ step: String) -> String { hue == .white ? "neutral.0" : "\(hue.rawValue).\(step)" }
        func lightness(_ k: String) -> Double { ObsidianTokens.palette[k]?.l ?? 1 }
        var notes: [String] = []
        let lowKey = key(low == .white ? .sky : low, "600")
        var midKey = key(mid == .white ? .orange : mid, "400")
        if abs(lightness(midKey) - lightness(lowKey)) < gap {
            midKey = key(mid == .white ? .orange : mid, "200")
            notes.append("Mid lightened so it stays distinct from Low.")
        }
        var highKey = key(high, "200")
        if abs(lightness(highKey) - lightness(midKey)) < gap, highKey != "neutral.0" {
            highKey = "neutral.0"
            notes.append("High set to white so it stays distinct from Mid.")
        }
        return Resolved(low: lowKey, mid: midKey, high: highKey, notes: notes)
    }
}
