import Foundation
import Observation

/// Everything in Settings except Appearance. Codable so it persists as one JSON value and so a
/// newer app version can add fields: missing keys decode to their defaults.
public struct Preferences: Codable, Equatable {
    public var audio = AudioPrefs()
    public var mixing = MixingPrefs()
    public var library = LibraryPrefs()
    public var session = SessionPrefs()
    public var controller = ControllerPrefs()
    public var visualizer = VisualizerPrefs()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audio = (try? c.decode(AudioPrefs.self, forKey: .audio)) ?? AudioPrefs()
        mixing = (try? c.decode(MixingPrefs.self, forKey: .mixing)) ?? MixingPrefs()
        library = (try? c.decode(LibraryPrefs.self, forKey: .library)) ?? LibraryPrefs()
        session = (try? c.decode(SessionPrefs.self, forKey: .session)) ?? SessionPrefs()
        controller = (try? c.decode(ControllerPrefs.self, forKey: .controller)) ?? ControllerPrefs()
        visualizer = (try? c.decode(VisualizerPrefs.self, forKey: .visualizer)) ?? VisualizerPrefs()
    }
}

public struct AudioPrefs: Codable, Equatable {
    /// A Y-splitter on one stereo output: master on the left, cue on the right (both mono).
    public var splitterCable = false
    /// macOS: a Core Audio device UID; iOS: a port UID. nil = choose automatically.
    public var masterOutputID: String?
    public var cueOutputID: String?
    /// iOS only: use multi-route when a second wired output exists.
    public var allowMultiRoute = true
    /// Hardware buffer in frames. 0 = the system's default.
    public var bufferFrames = 256
    /// Master output ceiling in dBFS (look-ahead limiter).
    public var limiterCeilingDb = -0.3

    public static let bufferChoices = [0, 64, 128, 256, 512, 1024]

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = AudioPrefs()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        splitterCable = (try? c.decode(Bool.self, forKey: .splitterCable)) ?? d.splitterCable
        masterOutputID = try? c.decodeIfPresent(String.self, forKey: .masterOutputID)
        cueOutputID = try? c.decodeIfPresent(String.self, forKey: .cueOutputID)
        allowMultiRoute = (try? c.decode(Bool.self, forKey: .allowMultiRoute)) ?? d.allowMultiRoute
        bufferFrames = (try? c.decode(Int.self, forKey: .bufferFrames)) ?? d.bufferFrames
        limiterCeilingDb = (try? c.decode(Double.self, forKey: .limiterCeilingDb)) ?? d.limiterCeilingDb
    }
}

public struct MixingPrefs: Codable, Equatable {
    public var transition: TransitionKind = .bassSwap
    public var transitionBeats = 16
    /// Transitions start on the outgoing track's next phrase of this many beats.
    public var phraseBeats = 16
    /// Cue points, loops and pads snap to the beat grid.
    public var quantize = true
    /// Level-match tracks by loudness (BS.1770) on load.
    public var autoGain = true
    /// 0 = smooth blend, 1 = sharp cut (scratch).
    public var crossfaderCurve = 0.0
    /// Tempo fader range in percent: 8, 16 or 50.
    public var pitchRange = 8
    /// When a track loads, place it on its first beat instead of 0:00.
    public var loadAtFirstBeat = true
    /// When a track loads on the stopped deck, turn its headphone cue on.
    public var autoCueOnLoad = true

    public static let transitionBeatChoices = [4, 8, 16, 32]
    public static let phraseChoices = [8, 16, 32]
    public static let pitchRangeChoices = [8, 16, 50]

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = MixingPrefs()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transition = (try? c.decode(TransitionKind.self, forKey: .transition)) ?? d.transition
        transitionBeats = (try? c.decode(Int.self, forKey: .transitionBeats)) ?? d.transitionBeats
        phraseBeats = (try? c.decode(Int.self, forKey: .phraseBeats)) ?? d.phraseBeats
        quantize = (try? c.decode(Bool.self, forKey: .quantize)) ?? d.quantize
        autoGain = (try? c.decode(Bool.self, forKey: .autoGain)) ?? d.autoGain
        crossfaderCurve = (try? c.decode(Double.self, forKey: .crossfaderCurve)) ?? d.crossfaderCurve
        pitchRange = (try? c.decode(Int.self, forKey: .pitchRange)) ?? d.pitchRange
        loadAtFirstBeat = (try? c.decode(Bool.self, forKey: .loadAtFirstBeat)) ?? d.loadAtFirstBeat
        autoCueOnLoad = (try? c.decode(Bool.self, forKey: .autoCueOnLoad)) ?? d.autoCueOnLoad
    }
}

public struct LibraryPrefs: Codable, Equatable {
    /// macOS only. iOS always copies: files picked from Files are only lent to the app.
    public var copyIntoLibrary = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        copyIntoLibrary = (try? c.decode(Bool.self, forKey: .copyIntoLibrary)) ?? false
    }

    /// What import actually does on this platform.
    public var effectiveCopy: Bool {
        #if os(iOS)
        true
        #else
        copyIntoLibrary
        #endif
    }
}

public struct SessionPrefs: Codable, Equatable {
    /// Reopen the last session at launch (decks restore paused, never playing).
    public var restoreLastSession = true
    /// iOS: keep the screen on while the app is open.
    public var keepScreenOn = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restoreLastSession = (try? c.decode(Bool.self, forKey: .restoreLastSession)) ?? true
        keepScreenOn = (try? c.decode(Bool.self, forKey: .keepScreenOn)) ?? true
    }
}

public struct ControllerPrefs: Codable, Equatable {
    /// Touching the top of the jog wheel scratches (vinyl). Off: the whole wheel bends pitch (CDJ).
    public var vinylMode = true
    /// Revolutions of the record per revolution of the on-screen wheel.
    public var jogSensitivity = 1.0
    /// Start and stop time in seconds: 0 = instant (CDJ), > 0 = a turntable's spin-up and brake.
    public var motorTime = 0.0

    public static let sensitivityChoices: [Double] = [0.5, 1.0, 2.0]
    public static let motorChoices: [Double] = [0, 0.3, 0.8]

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = ControllerPrefs()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vinylMode = c.value(.vinylMode, d.vinylMode)
        jogSensitivity = c.value(.jogSensitivity, d.jogSensitivity)
        motorTime = c.value(.motorTime, d.motorTime)
    }
}

/// Persists Preferences in UserDefaults, next to Appearance.
@MainActor
@Observable
public final class PreferencesStore {
    public var prefs: Preferences { didSet { if prefs != oldValue { save() } } }
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "soundboard.preferences.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let p = try? JSONDecoder().decode(Preferences.self, from: data) {
            prefs = p
        } else {
            prefs = Preferences()
        }
    }

    public func resetAudio() { prefs.audio = AudioPrefs() }
    public func resetAll() { prefs = Preferences() }

    private func save() {
        if let data = try? JSONEncoder().encode(prefs) { defaults.set(data, forKey: Self.key) }
    }
}
