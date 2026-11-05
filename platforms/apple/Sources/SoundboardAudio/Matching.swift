import Foundation
import SoundboardEngine

/// What the matcher needs to know about a track.
public struct TrackFacts: Sendable, Equatable {
    public var bpm: Double
    public var keyIndex: Int      // 0–11 major, 12–23 minor, −1 unknown
    public var loudnessLUFS: Double

    public init(bpm: Double, keyIndex: Int, loudnessLUFS: Double) {
        self.bpm = bpm
        self.keyIndex = keyIndex
        self.loudnessLUFS = loudnessLUFS
    }
}

/// Ranks "what plays well next": tempo within reach (half/double-time aware), harmonic
/// compatibility on the Camelot wheel, and similar energy. Pure logic, unit-tested.
public enum TrackMatcher {
    public enum Harmony: Equatable, Sendable { case same, compatible, clash, unknown }

    public struct Match: Equatable, Sendable {
        public var score: Double          // higher is better, 0…1
        public var tempoChangePercent: Double
        public var harmony: Harmony

        public init(score: Double, tempoChangePercent: Double, harmony: Harmony) {
            self.score = score
            self.tempoChangePercent = tempoChangePercent
            self.harmony = harmony
        }
    }

    /// Tempo change (in %) needed to match `candidate` to `current`, choosing ×½, ×1 or ×2.
    public static func tempoChangePercent(from candidate: Double, to current: Double) -> Double {
        guard candidate > 0, current > 0 else { return .infinity }
        let best = [0.5, 1.0, 2.0].map { current * $0 / candidate }.min { abs(log($0)) < abs(log($1)) } ?? 1
        return (best - 1) * 100
    }

    public static func harmony(_ a: Int, _ b: Int) -> Harmony {
        guard a >= 0, b >= 0 else { return .unknown }
        if a == b { return .same }
        return sbe_keys_compatible(Int32(a), Int32(b)) != 0 ? .compatible : .clash
    }

    public static func match(current: TrackFacts, candidate: TrackFacts) -> Match {
        let tempo = tempoChangePercent(from: candidate.bpm, to: current.bpm)
        let h = harmony(current.keyIndex, candidate.keyIndex)
        // Tempo: full marks within ±2 %, falling to zero at ±8 % (beyond that keylock artefacts and
        // audible pitch shift make the blend a poor beginner suggestion).
        let t = max(0, min(1, 1 - (abs(tempo) - 2) / 6))
        let k: Double = switch h {
        case .same: 1
        case .compatible: 0.85
        case .unknown: 0.5
        case .clash: 0.1
        }
        let energy = max(0, 1 - abs(current.loudnessLUFS - candidate.loudnessLUFS) / 8)
        return Match(score: 0.5 * t + 0.35 * k + 0.15 * energy, tempoChangePercent: tempo, harmony: h)
    }

    public static func rank<ID: Hashable>(current: TrackFacts, candidates: [(ID, TrackFacts)]) -> [(ID, Match)] {
        candidates.map { ($0.0, match(current: current, candidate: $0.1)) }
            .sorted { $0.1.score > $1.1.score }
    }
}

/// Bars and phrases from a beat position (4 beats per bar, 16 per phrase by default).
public enum PhraseClock {
    public static func bar(atBeat beat: Double) -> Int { Int(floor(beat / 4)) + 1 }

    public static func beatsToNextPhrase(atBeat beat: Double, phraseBeats: Int = 16) -> Int {
        let p = Double(phraseBeats)
        let next = (floor(beat / p) + 1) * p
        return max(1, Int(ceil(next - beat - 1e-9)))
    }

    public static func barsToNextPhrase(atBeat beat: Double, phraseBeats: Int = 16) -> Int {
        Int(ceil(Double(beatsToNextPhrase(atBeat: beat, phraseBeats: phraseBeats)) / 4))
    }
}
