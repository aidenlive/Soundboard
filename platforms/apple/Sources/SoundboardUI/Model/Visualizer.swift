import Accelerate
import Foundation
import Observation
import SoundboardAudio

/// What the visualizer draws.
public enum VisualizerStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case spectrum, radial, scope, pulse
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .spectrum: "Spectrum"
        case .radial: "Radial"
        case .scope: "Scope"
        case .pulse: "Pulse"
        }
    }
}

/// Colours for the visualizer, independent of the app's controls.
public enum VisualizerPalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case spectral, accent, mono
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .spectral: "Spectral"
        case .accent: "Accent"
        case .mono: "Mono"
        }
    }
}

public struct VisualizerPrefs: Codable, Equatable, Sendable {
    public var style: VisualizerStyle = .spectrum
    public var palette: VisualizerPalette = .spectral
    /// Gain into the bands: 0.5 calm … 2 lively.
    public var sensitivity = 1.0
    /// Flash and scale on the beat of the track on air.
    public var beatReactive = true
    /// Title, artist and BPM over the visuals.
    public var showTrackInfo = true
    /// iPhone/iPad: put the visualizer on an external display or AirPlay screen when one connects.
    public var useExternalDisplay = true

    public static let sensitivityChoices: [Double] = [0.5, 1, 1.5, 2]

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = VisualizerPrefs()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = c.value(.style, d.style)
        palette = c.value(.palette, d.palette)
        sensitivity = c.value(.sensitivity, d.sensitivity)
        beatReactive = c.value(.beatReactive, d.beatReactive)
        showTrackInfo = c.value(.showTrackInfo, d.showTrackInfo)
        useExternalDisplay = c.value(.useExternalDisplay, d.useExternalDisplay)
    }
}

/// One frame of analysed audio, refreshed at display rate.
public struct VisualFrame: Equatable, Sendable {
    /// 32 log-spaced bands, 30 Hz–16 kHz, 0…1 (attack fast, release slow).
    public var bands: [Float] = Array(repeating: 0, count: 32)
    /// The newest 512 samples, for the scope.
    public var scope: [Float] = Array(repeating: 0, count: 512)
    /// Overall level 0…1.
    public var level: Float = 0
    /// Position in the current beat of the deck on air (0…1), and whether a deck is playing.
    public var beatPhase: Double = 0
    public var playing = false
    public var bpm: Double = 0
    public var title = ""
    public var artist = ""
}

/// Turns the engine's master tap into `VisualFrame`s. Runs only while a visualizer is on screen
/// (views call `acquire` / `release`), on the main thread: one 2048-point FFT per frame, ≈ 0.1 ms.
@MainActor
@Observable
public final class VisualizerFeed {
    public private(set) var frame = VisualFrame()
    @ObservationIgnored weak var session: DJSession?
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let n = 2048
    @ObservationIgnored private lazy var dft = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)
    @ObservationIgnored private lazy var window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    @ObservationIgnored private var samples: [Float] = []
    @ObservationIgnored private var smoothed: [Float] = Array(repeating: 0, count: 32)

    public init() {}

    public func acquire() {
        users += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    public func release() {
        users = max(0, users - 1)
        if users == 0 { timer?.invalidate(); timer = nil }
    }

    private func tick() {
        guard let session else { return }
        if samples.count != n { samples = Array(repeating: 0, count: n) }
        let got = session.readVisual(into: &samples)
        var f = frame
        let sensitivity = Float(session.preferences.prefs.visualizer.sensitivity)
        if got == n {
            f.bands = bands(sensitivity: sensitivity)
            f.scope = Array(samples.suffix(512))
            let rms = sqrt(vDSP.meanSquare(samples))
            f.level = min(1, rms * 3 * sensitivity)
        } else {
            f.bands = smoothed.map { $0 * 0.9 }
            smoothed = f.bands
            f.level *= 0.9
        }
        let onAir = session.decks.first { $0.playing } ?? session.decks.first { $0.loaded }
        f.playing = session.decks.contains { $0.playing }
        f.beatPhase = onAir.map { $0.beat - floor($0.beat) } ?? 0
        f.bpm = onAir?.effectiveBpm ?? 0
        f.title = onAir?.title ?? ""
        f.artist = onAir?.artist ?? ""
        if f != frame { frame = f }
    }

    private func bands(sensitivity: Float) -> [Float] {
        guard let dft else { return smoothed }
        let windowed = vDSP.multiply(samples, window)
        let (re, im) = dft.transform(inputReal: windowed, inputImaginary: [Float](repeating: 0, count: n))
        let half = n / 2
        var mags = [Float](repeating: 0, count: half)
        for k in 1..<half { mags[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() / Float(n) }
        let rate = Float(session?.sampleRate ?? 48_000)
        let lo: Float = 30, hi: Float = min(16_000, rate / 2)
        var out = [Float](repeating: 0, count: 32)
        for b in 0..<32 {
            let f0 = lo * pow(hi / lo, Float(b) / 32), f1 = lo * pow(hi / lo, Float(b + 1) / 32)
            let k0 = max(1, Int(f0 / rate * Float(n))), k1 = min(half - 1, max(k0, Int(f1 / rate * Float(n))))
            var peak: Float = 0
            for k in k0...k1 { peak = max(peak, mags[k]) }
            // −66 dB … −6 dB → 0 … 1, with a gentle tilt so highs are not always dim.
            let db = 20 * log10(max(peak, 1e-9)) + Float(b) * 0.25
            let v = min(1, max(0, (db + 66) / 60 * sensitivity))
            out[b] = v > smoothed[b] ? v : smoothed[b] * 0.86 + v * 0.14
        }
        smoothed = out
        return out
    }
}

/// Shared between the app's window, the macOS visualizer window and an iOS external display.
@MainActor
@Observable
public final class VisualizerHub {
    public static let shared = VisualizerHub()
    public let feed = VisualizerFeed()
    public private(set) var session: DJSession?
    /// An external display or AirPlay screen is showing the visualizer (iOS).
    public internal(set) var externalDisplayActive = false

    func attach(_ session: DJSession) {
        self.session = session
        feed.session = session
    }
}

extension DJSession {
    /// Copies the newest master samples (mono) for visualizers. Returns how many were copied.
    func readVisual(into buffer: inout [Float]) -> Int {
        guard let e = engineHandle else { return 0 }
        let count = Int32(buffer.count)
        return Int(buffer.withUnsafeMutableBufferPointer { sbe_engine_read_visual(e, $0.baseAddress, count) })
    }
}
