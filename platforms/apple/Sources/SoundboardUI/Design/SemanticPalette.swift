import Foundation

/// The semantic colours for one Appearance, resolved from the generated token data.
/// Components read these, never palette entries.
public struct SemanticPalette: Equatable, Sendable {
    public enum Deck: Sendable { case a, b }

    public var background, surface, surface2, surface3, border: OKLCH
    public var text, textSecondary, textMuted: OKLCH
    public var primary, primaryHover, primaryActive, onPrimary: OKLCH
    public var success, warning, error, info: OKLCH
    public var cues: [OKLCH]
    public var waveA: Bands
    public var waveB: Bands

    public struct Bands: Equatable, Sendable {
        public var low, mid, high: OKLCH
    }

    public func wave(_ deck: Deck) -> Bands { deck == .a ? waveA : waveB }

    public enum ResolveError: Error, Equatable {
        case unresolved(String)
    }

    /// Resolve every semantic token for the given choices. Throws if any reference is broken,
    /// which the test suite checks for every combination.
    public static func resolve(_ appearance: Appearance, systemIsDark: Bool = true) throws -> SemanticPalette {
        let theme = appearance.effectiveTheme(systemIsDark: systemIsDark)
        let accentMap = ObsidianTokens.accents[appearance.accent.rawValue] ?? [:]
        let family = accentMap["family"] ?? "lime"
        var refs: [String: String] = ObsidianTokens.always
        refs.merge(ObsidianTokens.themes[theme.rawValue] ?? [:]) { $1 }
        refs.merge(accentMap.filter { $0.key != "family" }) { $1 }

        func resolveRef(_ ref: String, _ table: [String: String], depth: Int = 0) throws -> OKLCH {
            guard depth < 8, ref.hasPrefix("{"), ref.hasSuffix("}") else { throw ResolveError.unresolved(ref) }
            var key = String(ref.dropFirst().dropLast())
            if key.hasPrefix("accent.") { key = family + key.dropFirst("accent".count) }
            if let c = ObsidianTokens.palette[key] { return c }
            if let next = table[key] { return try resolveRef(next, table, depth: depth + 1) }
            throw ResolveError.unresolved(ref)
        }
        func color(_ name: String, _ table: [String: String] = refs) throws -> OKLCH {
            guard let ref = table[name] else { throw ResolveError.unresolved(name) }
            return try resolveRef(ref, table)
        }
        func bands(_ deck: Deck) throws -> Bands {
            if appearance.waveform == .custom {
                let r = appearance.customWaveform.resolve()
                func p(_ k: String) throws -> OKLCH {
                    guard let c = ObsidianTokens.palette[k] else { throw ResolveError.unresolved(k) }
                    return c
                }
                return Bands(low: try p(r.low), mid: try p(r.mid), high: try p(r.high))
            }
            var table = refs
            table.merge(ObsidianTokens.waveforms[appearance.waveform.rawValue] ?? [:]) { $1 }
            if deck == .b { table.merge(ObsidianTokens.waveforms["\(appearance.waveform.rawValue)/deck-b"] ?? [:]) { $1 } }
            return Bands(low: try color("color-wave-low", table), mid: try color("color-wave-mid", table),
                         high: try color("color-wave-high", table))
        }

        return SemanticPalette(
            background: try color("color-background"), surface: try color("color-surface"),
            surface2: try color("color-surface-2"), surface3: try color("color-surface-3"),
            border: try color("color-border"), text: try color("color-text"),
            textSecondary: try color("color-text-secondary"), textMuted: try color("color-text-muted"),
            primary: try color("color-primary"), primaryHover: try color("color-primary-hover"),
            primaryActive: try color("color-primary-active"), onPrimary: try color("color-on-primary"),
            success: try color("color-success"), warning: try color("color-warning"),
            error: try color("color-error"), info: try color("color-info"),
            cues: [try color("color-cue-1"), try color("color-cue-2"), try color("color-cue-3"), try color("color-cue-4")],
            waveA: try bands(.a), waveB: try bands(.b))
    }

    /// Never fails in practice (the tests resolve every combination); falls back to the default.
    public static func make(_ appearance: Appearance, systemIsDark: Bool = true) -> SemanticPalette {
        if let p = try? resolve(appearance, systemIsDark: systemIsDark) { return p }
        // swiftlint:disable:next force_try
        return try! resolve(Appearance())
    }
}
