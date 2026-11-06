import Foundation
import Observation
import SoundboardAudio
#if os(iOS)
import AVFAudio
import UIKit
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
    public var loopIn = 0.0
    public var loopOut = 0.0
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
    public var elapsed: Double { max(0, visual.position / max(1, sampleRate)) }
    public var deck: SemanticPalette.Deck { index == 0 ? .a : .b }
    public var letter: String { index == 0 ? "A" : "B" }
    public var mixerIsNeutral: Bool { trim == 0 && high == 0 && mid == 0 && low == 0 && filter == 0 && fader == 1 }
}

public enum TransitionKind: String, CaseIterable, Identifiable, Codable, Sendable {
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

/// Where the app is in starting up. The loading screen follows this.
public enum StartupPhase: Equatable { case launching, restoring, ready }

/// The running DJ session: engine, routing, decks, mixer, queue. The library, saved sessions
/// and preferences are separate stores this object reads and writes.
@MainActor
@Observable
public final class DJSession {
    public let library: LibraryStore
    public let sessions: SessionStore
    public let preferences: PreferencesStore

    public private(set) var phase: StartupPhase = .launching
    public private(set) var decks = [DeckState(index: 0), DeckState(index: 1)]
    public private(set) var queue: [UUID] = []
    public var workspace = WorkspaceSnapshot()
    public private(set) var plan: RoutePlan?
    public private(set) var outputs: [OutputPort] = []
    public private(set) var masterPeak: Float = 0
    public private(set) var cuePeak: Float = 0
    public private(set) var transitionProgress: Float = -1
    public private(set) var transitionStartsInBeats: Float = -1
    public private(set) var previewingID: UUID?
    public private(set) var errorMessage: String?
    /// Output latency and buffer actually in effect, for Settings › Audio.
    public private(set) var measuredBufferFrames = 0
    public private(set) var measuredOutputLatency: TimeInterval = 0
    public private(set) var sampleRate: Double = 0

    public var transition: TransitionKind = .bassSwap
    public var transitionBeats = 16
    public var crossfader = -1.0 {
        didSet { if !mirroringEngine { send { sbe_mixer_set_crossfader($0, Float(self.crossfader)) } } }
    }
    public var cueMix = 0.0 { didSet { send { sbe_mixer_set_cue_mix($0, Float(self.cueMix)) } } }
    public var masterVolume = 0.85 { didSet { send { sbe_mixer_set_master_gain($0, Self.volumeDb(self.masterVolume)) } } }
    public var headphoneVolume = 0.8 { didSet { send { sbe_mixer_set_headphone_gain($0, Self.volumeDb(self.headphoneVolume)) } } }

    @ObservationIgnored private var host: EngineHost?
    @ObservationIgnored private var mirroringEngine = false
    @ObservationIgnored private var previewRequest = 0
    @ObservationIgnored private var loadRequest = [0, 0]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var autosaveTimer: Timer?
    /// Cue points just sent to the engine. Until the engine reports them back, its (still empty)
    /// cues must not overwrite the library's.
    @ObservationIgnored private var pendingCues: [Int: (cues: [Double], polls: Int)] = [:]
    @ObservationIgnored private var started = false
    #if os(iOS)
    @ObservationIgnored private let audioSession = AudioSessionController()
    #endif

    public init(library: LibraryStore = LibraryStore(), sessions: SessionStore = SessionStore(),
                preferences: PreferencesStore = PreferencesStore()) {
        self.library = library
        self.sessions = sessions
        self.preferences = preferences
        let m = preferences.prefs.mixing
        transition = m.transition
        transitionBeats = m.transitionBeats
        library.onRemove = { [weak self] id in self?.forget(id) }
    }

    private var prefs: Preferences { preferences.prefs }

    // MARK: Lifecycle

    /// Starts audio, loads the library and restores the last session. Safe to call twice.
    public func start() async {
        guard !started else { return }
        started = true
        phase = .launching
        library.load()
        sessions.load()
        #if os(iOS)
        audioSession.onRouteChange = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.activateAudioSession()
                self.replan()
            }
        }
        audioSession.onMediaServicesReset = { [weak self] in
            Task { @MainActor [weak self] in await self?.recoverFromMediaReset() }
        }
        await activateAudioSession()
        #endif
        rebuildEngine()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        phase = .restoring
        if prefs.session.restoreLastSession, let id = sessions.lastOpenedID, let doc = sessions.document(id) {
            sessions.open(id)
            await restore(doc)
        } else if let doc = sessions.lastOpenedID.flatMap({ sessions.document($0) }) {
            // Not restoring decks, but keep working in the same named session.
            sessions.open(doc.id)
            var fresh = SessionDocument(id: doc.id)
            fresh.workspace = doc.workspace
            await restore(fresh)
        } else {
            sessions.create(named: "My session")
        }
        applyScreenPolicy()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        phase = .ready
    }

    #if os(iOS)
    private func activateAudioSession() async {
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        let multi = prefs.audio.allowMultiRoute && AudioSessionController.multiRouteCandidate(ports)
        let frames = prefs.audio.bufferFrames
        do {
            try await audioSession.activate(preferMultiRoute: multi,
                                            preferredBuffer: frames > 0 ? Double(frames) / 48_000 : 0.005)
        } catch {
            errorMessage = "Audio session: \(error.localizedDescription)"
        }
    }

    /// iOS restarts its audio server rarely (and under the debugger). Rebuild the engine and put
    /// the decks back where they were rather than losing the set.
    private func recoverFromMediaReset() async {
        let snapshot = self.snapshot()
        await activateAudioSession()
        rebuildEngine()
        await restore(snapshot)
    }
    #endif

    private func rebuildEngine() {
        #if os(iOS)
        let rate = audioSession.sampleRate > 0 ? audioSession.sampleRate : 48_000
        #else
        let rate = CoreAudioDevices.defaultOutputDevice().map(CoreAudioDevices.nominalSampleRate) ?? 48_000
        #endif
        sampleRate = rate > 0 ? rate : 48_000
        host = EngineHost(sampleRate: sampleRate, maxBlock: 4096, decks: 2)
        applyEngineSettings()
        decks = [DeckState(index: 0), DeckState(index: 1)]
        replan()
    }

    /// Pushes every engine-side setting: mixing preferences and the master/headphone mixer.
    private func applyEngineSettings() {
        let m = prefs.mixing
        let ceiling = prefs.audio.limiterCeilingDb
        send { e in
            sbe_engine_set_quantize(e, m.quantize ? 1 : 0)
            sbe_engine_set_auto_gain(e, m.autoGain ? 1 : 0)
            sbe_mixer_set_crossfader_curve(e, Float(m.crossfaderCurve))
            sbe_mixer_set_limiter_ceiling(e, Float(ceiling))
            sbe_mixer_set_crossfader(e, Float(self.crossfader))
            sbe_mixer_set_cue_mix(e, Float(self.cueMix))
            sbe_mixer_set_master_gain(e, Self.volumeDb(self.masterVolume))
            sbe_mixer_set_headphone_gain(e, Self.volumeDb(self.headphoneVolume))
        }
    }

    /// Settings changed. Audio changes re-plan the outputs; the rest apply live.
    public func preferencesChanged(from old: Preferences) {
        let new = prefs
        if old.mixing != new.mixing || old.audio.limiterCeilingDb != new.audio.limiterCeilingDb { applyEngineSettings() }
        if old.mixing.transition != new.mixing.transition { transition = new.mixing.transition }
        if old.mixing.transitionBeats != new.mixing.transitionBeats { transitionBeats = new.mixing.transitionBeats }
        var audioOld = old.audio, audioNew = new.audio
        audioOld.limiterCeilingDb = 0
        audioNew.limiterCeilingDb = 0
        if audioOld != audioNew {
            #if os(iOS)
            Task { await activateAudioSession(); replan() }
            #else
            replan()
            #endif
        }
        if old.session != new.session { applyScreenPolicy() }
    }

    private func applyScreenPolicy() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = prefs.session.keepScreenOn
        #endif
    }

    /// Choose master/cue routing for whatever is plugged in, and (re)start the hardware.
    public func replan() {
        guard let host else { return }
        let a = prefs.audio
        #if os(iOS)
        audioSession.refreshOutputs()
        outputs = audioSession.outputs
        let plan = RoutePlanner.plan(outputs: outputs, splitterCable: a.splitterCable, capabilities: .iOS,
                                     preferredMasterID: a.masterOutputID, preferredCueID: a.cueOutputID)
        let channels = audioSession.hardwareChannels
        let ids: (UInt32?, UInt32?) = (nil, nil)
        #else
        let devices = CoreAudioDevices.outputDevices()
        outputs = devices.map(\.port)
        let defaultID = CoreAudioDevices.defaultOutputDevice()
        let preferred = a.masterOutputID ?? devices.first { $0.id == defaultID }?.port.id
        let plan = RoutePlanner.plan(outputs: outputs, splitterCable: a.splitterCable, capabilities: .macOS,
                                     preferredMasterID: preferred, preferredCueID: a.cueOutputID)
        let master = devices.first { $0.port.id == plan.masterPort?.id }
        let cue = devices.first { $0.port.id == plan.cuePort?.id }
        let channels = master?.port.channels ?? 2
        let ids: (UInt32?, UInt32?) = (master?.id, cue?.id)
        if a.bufferFrames > 0 {
            for id in [ids.0, ids.1].compactMap({ $0 }) { CoreAudioDevices.setBufferFrameSize(id, frames: UInt32(a.bufferFrames)) }
        }
        #endif
        self.plan = plan
        do {
            try host.start(plan: plan, hardwareChannels: channels, masterDevice: ids.0, cueDevice: ids.1)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't start audio: \(error.localizedDescription)"
        }
        #if os(iOS)
        measuredBufferFrames = Int((audioSession.ioBufferDuration * sampleRate).rounded())
        measuredOutputLatency = plan.masterPort?.latency ?? 0
        #else
        measuredBufferFrames = ids.0.map { Int(CoreAudioDevices.bufferFrameSize($0)) } ?? 0
        measuredOutputLatency = master?.port.latency ?? 0
        #endif
    }

    private func send(_ body: (OpaquePointer) -> Void) {
        if let e = host?.engine { body(e) }
    }

    // MARK: Polling

    private func poll() {
        guard let host else { return }
        let s = host.status()
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
            deck.loopIn = d.loop_in
            deck.loopOut = d.loop_out
            deck.visual.loop = d.loop_active != 0 && d.loop_out > d.loop_in ? d.loop_in...d.loop_out : nil
            deck.frames = d.frames
            deck.sampleRate = d.sample_rate
            deck.peak = d.peak
            deck.fader = Double(d.fader)
            let cues = withUnsafeBytes(of: d.hot_cues) { Array($0.bindMemory(to: Double.self)) }
            deck.hotCues = cues
            deck.visual.cues = cues.enumerated().compactMap { $0.element >= 0 ? (index: $0.offset, frame: $0.element) : nil }
            if deck != decks[i] { decks[i] = deck }
            persistTrackMarkers(deck: i, cues: cues, loopIn: d.loop_in, loopOut: d.loop_out)
        }
        host.collectGarbage()
    }

    /// Cue points and the loop belong to the track, so they follow it into every session.
    private func persistTrackMarkers(deck i: Int, cues: [Double], loopIn: Double, loopOut: Double) {
        guard let id = decks[i].trackID else { return }
        if let pending = pendingCues[i] {
            let arrived = zip(pending.cues, cues).allSatisfy { abs($0 - $1) < 0.5 }
            if arrived || pending.polls > 60 { pendingCues[i] = nil } else { pendingCues[i] = (pending.cues, pending.polls + 1); return }
        }
        library.setHotCues(id, cues)
        if loopOut > loopIn { library.setSavedLoop(id, SavedLoop(inFrame: loopIn, outFrame: loopOut)) }
    }

    // MARK: Library and queue

    public func importFiles(_ urls: [URL]) {
        library.importFiles(urls, copy: prefs.library.effectiveCopy)
    }

    public func track(_ id: UUID?) -> LibraryTrack? { library.track(id) }

    public func enqueue(_ ids: [UUID]) {
        for id in ids where !queue.contains(id) && !isLoaded(id) { queue.append(id) }
    }

    public func dequeue(_ ids: Set<UUID>) { queue.removeAll { ids.contains($0) } }
    public func moveQueue(from: IndexSet, to: Int) { queue.move(fromOffsets: from, toOffset: to) }
    public func clearQueue() { queue = [] }

    /// A track left the library: let go of it everywhere in the running session.
    private func forget(_ id: UUID) {
        for i in decks.indices where decks[i].trackID == id { eject(i) }
        queue.removeAll { $0 == id }
        if previewingID == id { stopPreview() }
    }

    /// The queue first, then the best matches for whatever is playing (tempo, key, energy).
    public var upNext: [(track: LibraryTrack, match: TrackMatcher.Match)] {
        let none = TrackMatcher.Match(score: 0, tempoChangePercent: 0, harmony: .unknown)
        let queued = queue.compactMap { library.track($0) }.filter { $0.state == .ready && !isLoaded($0.id) }
        let current = (decks.first(where: { $0.playing }) ?? decks.first(where: { $0.loaded })).flatMap { track($0.trackID)?.facts }
        let pool = library.readyTracks.filter { !isLoaded($0.id) && !queue.contains($0.id) }
        let ranked: [(track: LibraryTrack, match: TrackMatcher.Match)]
        if let current {
            let candidates = pool.compactMap { t in t.facts.map { (t.id, $0) } }
            ranked = TrackMatcher.rank(current: current, candidates: candidates).compactMap { pair in
                track(pair.0).map { (track: $0, match: pair.1) }
            }
        } else {
            ranked = pool.map { (track: $0, match: none) }
        }
        let queuedWithMatch = queued.map { t -> (track: LibraryTrack, match: TrackMatcher.Match) in
            if let current, let f = t.facts, let m = TrackMatcher.rank(current: current, candidates: [(t.id, f)]).first?.1 {
                return (track: t, match: m)
            }
            return (track: t, match: none)
        }
        return queuedWithMatch + ranked
    }

    private func isLoaded(_ id: UUID) -> Bool { decks.contains { $0.trackID == id } }

    // MARK: Decks

    /// Loads a track. `snapshot` restores position, tempo, loop, cue and mixer (session restore).
    public func load(_ id: UUID, deck i: Int, snapshot: DeckSnapshot? = nil) async {
        guard let lt = track(id), lt.state == .ready, let host, let url = library.url(for: lt) else { return }
        loadRequest[i] += 1
        let request = loadRequest[i]
        decks[i].loading = true
        defer { if loadRequest[i] == request { decks[i].loading = false } }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let t = try await Track.decode(url: url)
            // A later load on the same deck wins.
            guard loadRequest[i] == request else { return }
            if let a = lt.analysis { t.apply(a) }
            let waveform = LibraryIO.waveform(of: t)
            host.load(t, deck: i)
            queue.removeAll { $0 == id }
            var d = DeckState(index: i)
            d.trackID = id
            d.title = lt.title
            d.artist = lt.artist
            d.bpm = lt.analysis?.bpm ?? 0
            d.keyName = lt.analysis?.keyName ?? ""
            d.camelot = lt.analysis?.camelot ?? ""
            d.visual.waveform = waveform
            d.visual.bpm = lt.analysis?.bpm ?? 0
            d.visual.firstBeatFrame = lt.analysis?.firstBeatFrame ?? 0
            d.frames = Double(t.frames)
            d.sampleRate = t.sampleRate
            d.hotCues = lt.hotCues
            let start = snapshot?.position ?? (prefs.mixing.loadAtFirstBeat ? max(0, lt.analysis?.firstBeatFrame ?? 0) : 0)
            d.visual.position = start
            if let s = snapshot {
                d.trim = s.trim; d.high = s.high; d.mid = s.mid; d.low = s.low; d.filter = s.filter; d.fader = s.fader
            } else {
                d.trim = decks[i].trim; d.high = decks[i].high; d.mid = decks[i].mid
                d.low = decks[i].low; d.filter = decks[i].filter; d.fader = decks[i].fader
            }
            decks[i] = d
            pendingCues[i] = (lt.hotCues, 0)
            send { e in
                let n = Int32(i)
                for (k, frame) in lt.hotCues.enumerated() where frame >= 0 { sbe_deck_hot_cue_set(e, n, Int32(k), frame) }
                if let loop = snapshot?.loop ?? lt.savedLoop {
                    sbe_deck_set_loop(e, n, loop.inFrame, loop.outFrame, (snapshot?.loopActive ?? false) ? 1 : 0)
                }
                if start > 0 { sbe_deck_seek(e, n, start) }
            }
            applyMixer(i)
            if let s = snapshot {
                if abs(s.tempo - 1) > 1e-6 { send { sbe_deck_set_tempo($0, Int32(i), s.tempo) } }
                if s.syncLocked { send { sbe_deck_sync($0, Int32(i), 1) } }
                setHeadphoneCue(i, s.cueEnabled)
            } else if prefs.mixing.autoCueOnLoad, cueAvailable, decks[1 - i].playing {
                setHeadphoneCue(i, true)
            }
        } catch {
            guard loadRequest[i] == request else { return }
            errorMessage = "Couldn't load “\(lt.title)”: \(LibraryIO.message(for: error))"
        }
    }

    /// Takes the track off a deck. The mixer channel keeps its settings.
    public func eject(_ i: Int) {
        loadRequest[i] += 1
        if decks[i].playing && transitionProgress >= 0 { cancelTransition() }
        send { e in
            sbe_deck_pause(e, Int32(i))
            sbe_channel_set_cue(e, Int32(i), 0)
            sbe_deck_unload(e, Int32(i))
        }
        pendingCues[i] = nil
        var d = DeckState(index: i)
        d.trim = decks[i].trim; d.high = decks[i].high; d.mid = decks[i].mid
        d.low = decks[i].low; d.filter = decks[i].filter; d.fader = decks[i].fader
        decks[i] = d
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

    /// Every knob to centre, channel faders up, crossfader to the deck on air, headphone mix to default.
    /// Decks, tracks and transport are untouched.
    public func resetMixer() {
        for i in decks.indices {
            decks[i].trim = 0; decks[i].high = 0; decks[i].mid = 0; decks[i].low = 0
            decks[i].filter = 0; decks[i].fader = 1
            applyMixer(i)
        }
        let d = MixerSnapshot()
        if transitionProgress >= 0 || transitionStartsInBeats >= 0 { cancelTransition() }
        // The crossfader goes to whichever deck is on air, so a reset never cuts the music.
        switch (decks[0].playing, decks[1].playing) {
        case (false, true): crossfader = 1
        case (true, true): crossfader = 0
        default: crossfader = -1
        }
        cueMix = d.cueMix
        masterVolume = d.masterVolume
        headphoneVolume = d.headphoneVolume
    }

    public var mixerIsNeutral: Bool {
        let d = MixerSnapshot()
        return decks.allSatisfy(\.mixerIsNeutral) && cueMix == d.cueMix
            && masterVolume == d.masterVolume && headphoneVolume == d.headphoneVolume
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

    /// The beginner Mix button: load the next track if needed (queue first), sync it, and blend
    /// on the next phrase using the chosen style and length.
    public func mix() async {
        let from = decks.firstIndex(where: { $0.playing }) ?? 0
        let to = 1 - from
        if !decks[to].loaded, let next = upNext.first?.track {
            await load(next.id, deck: to)
        }
        guard decks[from].loaded, decks[to].loaded else { return }
        if !decks[from].playing { togglePlay(from); return }
        let phrase = Int32(prefs.mixing.phraseBeats)
        send { sbe_transition_start_on_phrase($0, Int32(from), Int32(to), Double(self.transitionBeats), self.transition.engineStyle, phrase) }
    }

    public func cancelTransition() { send { sbe_transition_cancel($0) } }

    // MARK: Headphone preview

    public func preview(_ id: UUID) async {
        previewRequest += 1
        let request = previewRequest
        guard let lt = track(id), let host, let url = library.url(for: lt) else { return }
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

    // MARK: Sessions

    /// The running session as a document.
    public func snapshot() -> SessionDocument {
        var doc = SessionDocument(id: sessions.currentID ?? UUID())
        doc.decks = decks.map { d in
            var s = DeckSnapshot()
            s.trackID = d.trackID
            s.position = d.visual.position
            s.tempo = d.tempo
            s.syncLocked = d.syncLocked
            s.loop = d.loopOut > d.loopIn ? SavedLoop(inFrame: d.loopIn, outFrame: d.loopOut) : nil
            s.loopActive = d.loopActive
            s.cueEnabled = d.cueEnabled
            s.trim = d.trim; s.high = d.high; s.mid = d.mid; s.low = d.low; s.filter = d.filter; s.fader = d.fader
            return s
        }
        doc.mixer = MixerSnapshot()
        doc.mixer.crossfader = crossfader
        doc.mixer.masterVolume = masterVolume
        doc.mixer.headphoneVolume = headphoneVolume
        doc.mixer.cueMix = cueMix
        doc.queue = queue
        doc.workspace = workspace
        return doc
    }

    /// Saves the running session (only if it changed) and the library.
    public func saveNow() {
        guard phase == .ready, sessions.currentID != nil else { return }
        sessions.save(snapshot())
    }

    /// Puts a session's decks, mixer, queue and workspace back. Decks restore paused.
    private func restore(_ doc: SessionDocument) async {
        for i in decks.indices where decks[i].loaded { eject(i) }
        queue = doc.queue.filter { library.track($0) != nil }
        workspace = doc.workspace
        if case .playlist(let id) = workspace.librarySource, !library.playlists.contains(where: { $0.id == id }) {
            workspace.librarySource = .all
        }
        crossfader = doc.mixer.crossfader
        masterVolume = doc.mixer.masterVolume
        headphoneVolume = doc.mixer.headphoneVolume
        cueMix = doc.mixer.cueMix
        for (i, s) in doc.decks.prefix(decks.count).enumerated() {
            decks[i].trim = s.trim; decks[i].high = s.high; decks[i].mid = s.mid
            decks[i].low = s.low; decks[i].filter = s.filter; decks[i].fader = s.fader
            applyMixer(i)
            if let id = s.trackID, library.track(id)?.state == .ready {
                await load(id, deck: i, snapshot: s)
            }
        }
    }

    public func switchSession(to id: UUID) async {
        guard id != sessions.currentID, let doc = sessions.document(id) else { return }
        saveNow()
        stopPreview()
        cancelTransition()
        sessions.open(id)
        await restore(doc)
    }

    /// A new, empty session (the library is shared, so nothing is lost).
    public func newSession(named name: String) async {
        saveNow()
        stopPreview()
        cancelTransition()
        let doc = sessions.create(named: name)
        await restore(doc)
    }

    public func duplicateSession(named name: String) {
        saveNow()
        let doc = sessions.create(named: name, from: snapshot())
        sessions.open(doc.id)
    }

    /// Deletes a session. Deleting the open one moves to the most recent other, or a new one.
    public func deleteSession(_ id: UUID) async {
        let wasCurrent = id == sessions.currentID
        sessions.delete(id)
        guard wasCurrent else { return }
        if let next = sessions.sessions.max(by: { $0.modified < $1.modified }), let doc = sessions.document(next.id) {
            sessions.open(next.id)
            await restore(doc)
        } else {
            await restore(sessions.create(named: "My session"))
        }
    }

    /// Clears decks, queue and mixer in the open session. The library is untouched.
    public func clearSession() async {
        await restore(SessionDocument(id: sessions.currentID ?? UUID()))
        saveNow()
    }
}
