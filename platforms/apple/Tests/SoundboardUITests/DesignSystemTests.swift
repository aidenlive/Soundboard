import Foundation
import XCTest
@testable import SoundboardUI
import SoundboardAudio

final class DesignSystemTests: XCTestCase {
    /// Every Appearance combination resolves every semantic token (no broken references).
    func testEveryAppearanceCombinationResolves() throws {
        for theme in Appearance.Theme.allCases {
            for accent in Appearance.Accent.allCases {
                for wave in Appearance.Waveform.allCases {
                    var a = Appearance()
                    a.theme = theme
                    a.accent = accent
                    a.waveform = wave
                    XCTAssertNoThrow(try SemanticPalette.resolve(a), "\(theme) \(accent) \(wave)")
                }
            }
        }
    }

    /// The generated Swift data matches the JSON source of truth (guards against a stale generate step).
    func testGeneratedTokensMatchJSON() throws {
        let json = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("design/tokens/obsidian.tokens.json")
        let data = try Data(contentsOf: json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let palette = try XCTUnwrap(root["palette"] as? [String: [String: String]])
        let count = palette.values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(ObsidianTokens.palette.count, count)
        for (family, steps) in palette {
            for (step, value) in steps {
                let c = try XCTUnwrap(ObsidianTokens.palette["\(family).\(step)"], "\(family).\(step)")
                XCTAssertTrue(value.hasPrefix(String(format: "oklch(%.3f", c.l)), "\(family).\(step) \(value)")
            }
        }
    }

    /// Text tokens keep WCAG AA contrast on their background in every theme.
    func testTextContrastInEveryTheme() throws {
        for theme in Appearance.Theme.allCases {
            var a = Appearance()
            a.theme = theme
            let p = try SemanticPalette.resolve(a)
            XCTAssertGreaterThanOrEqual(OKLCH.contrast(p.text, p.background), 4.5, "\(theme) text")
            XCTAssertGreaterThanOrEqual(OKLCH.contrast(p.textSecondary, p.background), 4.5, "\(theme) secondary")
            XCTAssertGreaterThanOrEqual(OKLCH.contrast(p.textMuted, p.background), 4.5, "\(theme) muted")
        }
    }

    /// Text on the accent (Mix button) is readable for every accent.
    func testOnPrimaryContrastForEveryAccent() throws {
        for accent in Appearance.Accent.allCases {
            var a = Appearance()
            a.accent = accent
            let p = try SemanticPalette.resolve(a)
            XCTAssertGreaterThanOrEqual(OKLCH.contrast(p.onPrimary, p.primary), 4.5, "\(accent)")
        }
    }

    func testDeckTintGivesEachDeckItsOwnColour() throws {
        var a = Appearance()
        a.waveform = .decktint
        let p = try SemanticPalette.resolve(a)
        XCTAssertNotEqual(p.waveA.low, p.waveB.low)
        a.waveform = .spectral
        let s = try SemanticPalette.resolve(a)
        XCTAssertEqual(s.waveA, s.waveB)
    }

    func testCustomWaveformGuardrails() {
        // Distinct picks pass untouched.
        let ok = CustomWaveform(low: .pink, mid: .orange, high: .white).resolve()
        XCTAssertEqual(ok.low, "pink.600")
        XCTAssertEqual(ok.mid, "orange.400")
        XCTAssertEqual(ok.high, "neutral.0")
        XCTAssertTrue(ok.notes.isEmpty)
        // Cyan low (L .71) vs sky mid (L .72): mid is lifted.
        let lifted = CustomWaveform(low: .cyan, mid: .sky, high: .white).resolve()
        XCTAssertEqual(lifted.mid, "sky.200")
        XCTAssertFalse(lifted.notes.isEmpty)
        // High too close to mid falls back to white.
        let white = CustomWaveform(low: .sky, mid: .cyan, high: .sky).resolve()
        XCTAssertEqual(white.high, "neutral.0")
        // Whatever the picks, adjacent bands end up at least partly separated.
        for l in CustomWaveform.Hue.allCases where l != .white {
            for m in CustomWaveform.Hue.allCases where m != .white {
                let r = CustomWaveform(low: l, mid: m, high: .sky).resolve()
                let gap = abs((ObsidianTokens.palette[r.mid]?.l ?? 0) - (ObsidianTokens.palette[r.low]?.l ?? 0))
                XCTAssertGreaterThanOrEqual(gap, 0.12, "\(l) \(m)")
            }
        }
    }

    func testOKLCHConversion() {
        let white = OKLCH(1, 0, 0).sRGB
        XCTAssertEqual(white.r, 1, accuracy: 0.002)
        XCTAssertEqual(white.g, 1, accuracy: 0.002)
        XCTAssertEqual(OKLCH(0, 0, 0).sRGB.b, 0, accuracy: 0.0001)
        // Volt lime matches the brand table (#AFF03C) in sRGB.
        let lime = OKLCH(0.88, 0.21, 128).sRGB
        XCTAssertEqual(lime.r * 255, 0xAF, accuracy: 1.5)
        XCTAssertEqual(lime.g * 255, 0xF0, accuracy: 1.5)
        XCTAssertEqual(lime.b * 255, 0x3C, accuracy: 1.5)
    }

    func testAppearanceFollowSystem() {
        var a = Appearance()
        a.followSystem = true
        XCTAssertEqual(a.effectiveTheme(systemIsDark: false), .daylight)
        XCTAssertEqual(a.effectiveTheme(systemIsDark: true), .oled)
        a.theme = .graphite
        XCTAssertEqual(a.effectiveTheme(systemIsDark: true), .graphite)
    }

    func testAppearanceRoundTrips() throws {
        var a = Appearance()
        a.theme = .graphite
        a.accent = .ember
        a.deckView = .radial
        a.waveform = .custom
        a.customWaveform = CustomWaveform(low: .violet, mid: .cyan, high: .white)
        let back = try JSONDecoder().decode(Appearance.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(a, back)
    }

    func testEqKnobMapping() {
        XCTAssertEqual(DJSession.eqDb(0), 0)
        XCTAssertEqual(DJSession.eqDb(1), 6)
        XCTAssertEqual(DJSession.eqDb(-1), -96)
        XCTAssertEqual(Double(DJSession.eqDb(-0.5)), -6.02, accuracy: 0.05)
        XCTAssertEqual(DJSession.eqText(-1), "kill")
    }
}

final class MatchingTests: XCTestCase {
    func testTempoChangeHandlesHalfAndDoubleTime() {
        XCTAssertEqual(TrackMatcher.tempoChangePercent(from: 126, to: 124), -1.587, accuracy: 0.01)
        XCTAssertEqual(TrackMatcher.tempoChangePercent(from: 87, to: 174), 0, accuracy: 0.001)
        XCTAssertEqual(TrackMatcher.tempoChangePercent(from: 174, to: 87), 0, accuracy: 0.001)
    }

    func testHarmony() {
        XCTAssertEqual(TrackMatcher.harmony(21, 21), .same)        // A minor
        XCTAssertEqual(TrackMatcher.harmony(21, 0), .compatible)   // A minor ↔ C major (8A/8B)
        XCTAssertEqual(TrackMatcher.harmony(0, 7), .compatible)    // C ↔ G (8B/9B)
        XCTAssertEqual(TrackMatcher.harmony(0, 6), .clash)         // C ↔ F#
        XCTAssertEqual(TrackMatcher.harmony(-1, 3), .unknown)
    }

    func testRankingPrefersCloseTempoAndCompatibleKey() {
        let now = TrackFacts(bpm: 124, keyIndex: 21, loudnessLUFS: -9)
        let ranked = TrackMatcher.rank(current: now, candidates: [
            ("far tempo", TrackFacts(bpm: 140, keyIndex: 21, loudnessLUFS: -9)),
            ("clash", TrackFacts(bpm: 125, keyIndex: 6, loudnessLUFS: -9)),
            ("best", TrackFacts(bpm: 126, keyIndex: 0, loudnessLUFS: -9.5)),
        ])
        XCTAssertEqual(ranked.map(\.0), ["best", "clash", "far tempo"])
    }

    func testPhraseClock() {
        XCTAssertEqual(PhraseClock.bar(atBeat: 0), 1)
        XCTAssertEqual(PhraseClock.bar(atBeat: 131.5), 33)
        XCTAssertEqual(PhraseClock.beatsToNextPhrase(atBeat: 6.2), 10)
        XCTAssertEqual(PhraseClock.beatsToNextPhrase(atBeat: 16), 16)
        XCTAssertEqual(PhraseClock.barsToNextPhrase(atBeat: 6.2), 3)
    }
}
