import Foundation
import Observation
import SoundboardAudio
#if os(iOS)
import AVFAudio
#endif

/// Live state of one deck, refreshed from the engine at display rate.
public struct DeckState: Equatable {
    public let index: Int
    public var trackID: UUID?
    public var title = ""
    public var artist = ""
    public var keyName = ""
    public var camelot = ""
    public var bpm = 0.0
    public var visual = DeckVisual()
    public var playing = false
    public var tempo = 1.0
    public var effectiveBpm = 0.0
    public var beat = 0.0
    public var syncLocked = false
    public var cueEnabled = false
    public var loopActive = false
    public var hotCues: [Double] = Array(repeating: -1, count: 8)
    public var frames = 0.0
    public var sampleRate = 44_100.0
    public var peak: Float = 0
    public var loading = false
    // Mixer controls, as knob positions (−1…1) and fader (0…1).
    public var trim = 0.0
    public var high = 0.0
    public var mid = 0.0
    public var low = 0.0
    public var filter = 0.0
    public var fader = 1.0

    public var loaded: Bool { trackID != nil }
    public var remaining: Double { max(0, (frames - visual.position) / max(1, sampleRate)) }
    public var deck: SemanticPalette.Deck { index == 0 ? .a : .b }
    public var letter: String { index == 0 ? "A" : "B" }
}

public enum TransitionKind: String, CaseIterable, Identifiable {
    case blend, bassSwap, echoOut, filter
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .blend: "Blend"
        case .bassSwap: "Bass swap"
        case .echoOut: "Echo out"
        case .filter: "Filter"
        }
    }
    var engineStyle: sbe_transition_style {
        switch self {
        case .blend: SBE_TRANSITION_BLEND
        case .bassSwap: SBE_TRANSITION_BASS_SWAP
        case .echoOut: SBE_TRANSITION_ECHO_OUT
        case .filter: SBE_TRANSITION_FILTER_SWEEP
        }
    }
}

/// The whole running DJ session: engine, routing, library, decks, mixer.
@MainActor
@Observable
public final class DJSession {
    public private(set) var decks = [DeckState(index: 0), DeckState(index: 1)]
    public private(set) var library: [LibraryTrack] = []
    public private(set) var plan: RoutePlan?
    public private(set) var outputs: [OutputPort] = []
    public private(set) var masterPeak: Float = 0
    public private(set) var cuePeak: Float = 0
    public private(set) var transitionProgress: Float = -1
    public private(set) var transitionStartsInBeats: Float = -1
    public private(set) var previewingID: UUID?
    public private(set) var errorMessage: String?

    public var transition: TransitionKind = .bassSwap
    public var transitionBeats = 16
    public var splitterCable = false { didSet { replan() } }
    public var crossfader = -1.0 {
        didSet { if !mirroringEngine { send { sbe_mixer_set_crossfader($0, Float(self.crossfader)) } } }
    }
    public var cueMix = 0.0 { didSet { send { sbe_mixer_set_cue_mix($0, Float(self.cueMix)) } } }
    public var masterVolume = 0.85 { didSet { send { sbe_mixer_set_master_gain($0, Self.volumeDb(self.masterVolume)) } } }
    public var headphoneVolume = 0.8 { didSet { send { sbe_mixer_set_headphone_gain($0, Self.volumeDb(self.headphoneVolume)) } } }

    @ObservationIgnored private var host: EngineHost?
    @ObservationIgnored private var mirroringEngine = false
    @ObservationIgnored private var previewRequest = 0
    @ObservationIgnored private var timer: Timer?
    #if os(iOS)
    @ObservationIgnored private let session = AudioSessionController()
    #endif
    @ObservationIgnored private var starting = false

    public init() {}

    // MARK: Lifecycle

    public func start() {
        guard host == nil, !starting else { return }
        #if os(iOS)
        starting = true
        session.onRouteChange = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.activateSession()
                self.replan()
            }
        }
        session.onMediaServicesReset = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.activateSession()
                self.rebuildEngine()
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.activateSession()
            self.starting = false
            self.finishStart()
        }
        #else
        finishStart()
        #endif
    }

    #if os(iOS)
    private func activateSession() async {
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        do {
            try await session.activate(preferMultiRoute: AudioSessionController.multiRouteCandidate(ports))
        } catch {
            errorMessage = "Audio session: \(error.localizedDescription)"
        }
    }
    #endif

    private func finishStart() {
        rebuildEngine()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func rebuildEngine() {
        #if os(iOS)
        let rate = session.sampleRate > 0 ? session.sampleRate : 48_000
        #else
        let rate = CoreAudioDevices.defaultOutputDevice().map(CoreAudioDevices.nominalSampleRate) ?? 48_000
        #endif
        host = EngineHost(sampleRate: rate > 0 ? rate : 48_000, maxBlock: 1024, decks: 2)
        send { e in
            sbe_engine_set_quantize(e, 1)
            sbe_mixer_set_crossfader(e, Float(self.crossfader))
            sbe_mixer_set_master_gain(e, Self.volumeDb(self.masterVolume))
            sbe_mixer_set_headphone_gain(e, Self.volumeDb(self.headphoneVolume))
        }
        decks = [DeckState(index: 0), DeckState(index: 1)]
        replan()
    }

    /// Choose master/cue routing for whatever is plugged in, and (re)start the hardware.
    public func replan() {
        guard let host else { return }
        #if os(iOS)
        session.refreshOutputs()
        outputs = session.outputs
        let plan = RoutePlanner.plan(outputs: outputs, splitterCable: splitterCable, capabilities: .iOS)
        let channels = session.hardwareChannels
        let ids: (UInt32?, UInt32?) = (nil, nil)
        #else
        let devices = CoreAudioDevices.outputDevices()
        outputs = devices.map(\.port)
        let defaultID = CoreAudioDevices.defaultOutputDevice()
        let preferred = devices.first { $0.id == defaultID }?.port.id
        let plan = RoutePlanner.plan(outputs: outputs, splitterCable: splitterCable, capabilities: .macOS, preferredMasterID: preferred)
        let master = devices.first { $0.port.id == plan.masterPort?.id }
        let cue = devices.first { $0.port.id == plan.cuePort?.id }
        let channels = master?.port.channels ?? 2
        let ids: (UInt32?, UInt32?) = (master?.id, cue?.id)
        #endif
        self.plan = plan
        do {
            try host.start(plan: plan, hardwareChannels: channels, masterDevice: ids.0, cueDevice: ids.1)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't start audio: \(error.localizedDescription)"
        }
    }

    private func send(_ body: (OpaquePointer) -> Void) {
        if let e = host?.engine { body(e) }
    }

    // MARK: Polling

    private func poll() {
        guard let host else { return }
        let s = host.status()
        // A transition (now, or one that just finished) is moving the crossfader in the engine.
        let automating = s.transition_progress >= 0 || transitionProgress >= 0
        // Only publish changes that are visible, so 60 Hz polling doesn't re-render idle views.
        if abs(s.master_peak - masterPeak) > 0.01 { masterPeak = s.master_peak }
        if abs(s.cue_peak - cuePeak) > 0.01 { cuePeak = s.cue_peak }
        if s.transition_progress != transitionProgress { transitionProgress = s.transition_progress }
        let wait = s.transition_starts_in_beats < 0 ? -1 : Float(Int(ceil(s.transition_starts_in_beats)))
        if wait != transitionStartsInBeats { transitionStartsInBeats = wait }
        // Transitions move the crossfader in the engine: mirror it so the UI never snaps it back.
        if automating, abs(Double(s.crossfader) - crossfader) > 0.002 {
            mirroringEngine = true
            crossfader = Double(s.crossfader)
            mirroringEngine = false
        }
        for i in decks.indices where decks[i].loaded {
            let d = host.deckStatus(i)
            var deck = decks[i]
            deck.visual.position = d.position
            deck.playing = d.playing != 0
            deck.tempo = d.tempo
            deck.effectiveBpm = d.effective_bpm
            deck.beat = d.beat
            deck.syncLocked = d.sync_locked != 0
            deck.cueEnabled = d.cue_enabled != 0
            deck.loopActive = d.loop_active != 0
            deck.visual.loop = d.loop_active != 0 && d.loop_out > d.loop_in ? d.loop_in...d.loop_out : nil
            deck.frames = d.frames
            deck.sampleRate = d.sample_rate
            deck.peak = d.peak
            deck.fader = Double(d.fader)
            let cues = withUnsafeBytes(of: d.hot_cues) { Array($0.bindMemory(to: Double.self)) }
            deck.hotCues = cues
            deck.visual.cues = cues.enumerated().compactMap { $0.element >= 0 ? (index: $0.offset, frame: $0.element) : nil }
            if deck != decks[i] { decks[i] = deck }
        }
        host.collectGarbage()
    }

    // MARK: Library

    public func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let id = UUID()
            library.append(LibraryTrack(id: id, title: url.deletingPathExtension().lastPathComponent, artist: "",
                                        url: url, bookmark: LibraryIO.bookmark(for: url)))
            Task {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let meta = await LibraryIO.metadata(for: url)
                update(id) { $0.title = meta.title; $0.artist = meta.artist; $0.duration = meta.duration }
                do {
                    let r = try await LibraryIO.analyse(url: url)
                    update(id) {
                        $0.analysis = r.analysis
                        $0.waveform = WaveformData(low: r.low, mid: r.mid, high: r.high, framesPerBin: r.framesPerBin, sampleRate: r.sampleRate)
                        $0.duration = r.duration
                        $0.state = .ready
                    }
                } catch {
                    update(id) { $0.state = .failed(error.localizedDescription) }
                }
            }
        }
    }

    public var analysingCount: Int { library.filter { $0.state == .analysing }.count }

    private func update(_ id: UUID, _ change: (inout LibraryTrack) -> Void) {
        guard let i = library.firstIndex(where: { $0.id == id }) else { return }
        change(&library[i])
    }

    public func track(_ id: UUID?) -> LibraryTrack? { library.first { $0.id == id } }

    /// Best next tracks for whatever is playing (tempo, key, energy), excluding loaded ones.
    public var upNext: [(track: LibraryTrack, match: TrackMatcher.Match)] {
        let playing = decks.first(where: { $0.playing }) ?? decks.first(where: { $0.loaded })
        guard let current = playing.flatMap({ track($0.trackID)?.facts }) else {
            return library.filter { $0.state == .ready && !isLoaded($0.id) }
                .map { (track: $0, match: TrackMatcher.Match(score: 0, tempoChangePercent: 0, harmony: .unknown)) }
        }
        let candidates = library.filter { $0.state == .ready && !isLoaded($0.id) }.compactMap { t in t.facts.map { (t.id, $0) } }
        return TrackMatcher.rank(current: current, candidates: candidates).compactMap { pair in
            track(pair.0).map { (track: $0, match: pair.1) }
        }
    }

    private func isLoaded(_ id: UUID) -> Bool { decks.contains { $0.trackID == id } }

    // MARK: Decks

    public func load(_ id: UUID, deck i: Int) async {
        guard let lt = track(id), lt.state == .ready, let host else { return }
        decks[i].loading = true
        defer { decks[i].loading = false }
        let url = lt.resolvedURL()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let t = try await Track.decode(url: url)
            if let a = lt.analysis { t.apply(a) }
            host.load(t, deck: i)
            var d = DeckState(index: i)
            d.trackID = id
            d.title = lt.title
            d.artist = lt.artist
            d.bpm = lt.analysis?.bpm ?? 0
            d.keyName = lt.analysis?.keyName ?? ""
            d.camelot = lt.analysis?.camelot ?? ""
            d.visual.waveform = lt.waveform
            d.visual.bpm = lt.analysis?.bpm ?? 0
            d.visual.firstBeatFrame = lt.analysis?.firstBeatFrame ?? 0
            d.visual.position = lt.analysis?.firstBeatFrame ?? 0
            d.frames = Double(t.frames)
            d.sampleRate = t.sampleRate
            decks[i] = d
            applyMixer(i)
        } catch {
            errorMessage = "Couldn't load \(lt.title): \(error.localizedDescription)"
        }
    }

    public func togglePlay(_ i: Int) { send { sbe_deck_toggle($0, Int32(i)) } }
    public func cuePress(_ i: Int) { send { sbe_deck_cue_press($0, Int32(i)) } }
    public func cueRelease(_ i: Int) { send { sbe_deck_cue_release($0, Int32(i)) } }
    public func sync(_ i: Int) {
        if decks[i].syncLocked { send { sbe_deck_unsync($0, Int32(i)) } } else { send { sbe_deck_sync($0, Int32(i), 1) } }
    }
    public func seek(_ i: Int, frame: Double) { send { sbe_deck_seek($0, Int32(i), frame) } }
    public func hotCue(_ i: Int, _ n: Int) { send { sbe_deck_hot_cue_trigger($0, Int32(i), Int32(n)) } }
    public func clearHotCue(_ i: Int, _ n: Int) { send { sbe_deck_hot_cue_clear($0, Int32(i), Int32(n)) } }
    public func beatLoop(_ i: Int, beats: Double) {
        if decks[i].loopActive { send { sbe_deck_loop_exit($0, Int32(i)) } } else { send { sbe_deck_beat_loop($0, Int32(i), beats) } }
    }
    public func beatJump(_ i: Int, beats: Double) { send { sbe_deck_beat_jump($0, Int32(i), beats) } }
    public func setHeadphoneCue(_ i: Int, _ on: Bool) { send { sbe_channel_set_cue($0, Int32(i), on ? 1 : 0) } }

    // MARK: Mixer (knob positions → engine units)

    public enum Control { case trim, high, mid, low, filter, fader }

    public func set(_ c: Control, deck i: Int, _ v: Double) {
        switch c {
        case .trim: decks[i].trim = v
        case .high: decks[i].high = v
        case .mid: decks[i].mid = v
        case .low: decks[i].low = v
        case .filter: decks[i].filter = v
        case .fader: decks[i].fader = v
        }
        applyMixer(i, only: c)
    }

    private func applyMixer(_ i: Int, only: Control? = nil) {
        let d = decks[i]
        send { e in
            let n = Int32(i)
            if only == nil || only == .trim { sbe_channel_set_trim(e, n, Float(d.trim * 12)) }
            if only == nil || only == .high { sbe_channel_set_eq(e, n, SBE_EQ_HIGH, Self.eqDb(d.high)) }
            if only == nil || only == .mid { sbe_channel_set_eq(e, n, SBE_EQ_MID, Self.eqDb(d.mid)) }
            if only == nil || only == .low { sbe_channel_set_eq(e, n, SBE_EQ_LOW, Self.eqDb(d.low)) }
            if only == nil || only == .filter { sbe_channel_set_filter(e, n, Float(d.filter)) }
            if only == nil || only == .fader { sbe_channel_set_fader(e, n, Float(d.fader)) }
        }
    }

    /// Knob → dB: +6 dB at the top; below centre a musical cut reaching a full kill at −1.
    nonisolated public static func eqDb(_ v: Double) -> Float {
        if v >= 0 { return Float(v * 6) }
        if v <= -0.97 { return -96 }
        return Float(20 * log10(1 + v))
    }

    nonisolated public static func eqText(_ v: Double) -> String {
        let db = eqDb(v)
        if db <= -80 { return "kill" }
        return abs(db) < 0.05 ? "0 dB" : String(format: "%+.1f dB", db)
    }

    nonisolated static func volumeDb(_ v: Double) -> Float { v <= 0.001 ? -96 : Float(40 * log10(v)) }

    // MARK: Transitions

    /// The beginner Mix button: load the best next track if needed, sync it, and blend on the
    /// next phrase using the chosen style and length.
    public func mix() async {
        let from = decks.firstIndex(where: { $0.playing }) ?? 0
        let to = 1 - from
        if !decks[to].loaded, let next = upNext.first?.track {
            await load(next.id, deck: to)
        }
        guard decks[from].loaded, decks[to].loaded else { return }
        if !decks[from].playing { togglePlay(from); return }
        send { sbe_transition_start_on_phrase($0, Int32(from), Int32(to), Double(self.transitionBeats), self.transition.engineStyle, 16) }
    }

    public func cancelTransition() { send { sbe_transition_cancel($0) } }

    // MARK: Headphone preview

    public func preview(_ id: UUID) async {
        previewRequest += 1
        let request = previewRequest
        guard let lt = track(id), let host else { return }
        let url = lt.resolvedURL()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let t = try? await Track.decode(url: url) else { return }
        // The user may have let go while the file was decoding.
        guard request == previewRequest else { return }
        // Start a third of the way in: usually past the intro, where the track's character is.
        host.preview(t, from: Double(t.frames) * 0.33)
        previewingID = id
    }

    public func stopPreview() {
        previewRequest += 1
        send { sbe_preview_stop($0) }
        previewingID = nil
    }

    public var cueAvailable: Bool { plan?.cueAvailable ?? false }
}
