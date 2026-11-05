import Foundation
import Observation
#if os(iOS)
import AVFAudio
#endif
import SoundboardAudio

/// Drives the Routing Lab: discovers outputs, plans master/cue routing, and plays two
/// unmistakable test signals so the routing can be verified by ear on real hardware.
///   Master: low 220 Hz pulse on every beat (what the crowd hears)
///   Cue:    high 880 Hz chirp on the off-beat (what only the DJ should hear)
@MainActor
@Observable
final class RoutingLabModel {
    var outputs: [OutputPort] = []
    var plan: RoutePlan?
    var splitterCable = false { didSet { replan() } }
    var masterPeak: Float = 0
    var cuePeak: Float = 0
    var cueUnderruns: UInt32 = 0
    var playing = false
    var errorMessage: String?

    private var host: EngineHost?
    private var masterTone: Track?
    private var cueTone: Track?
    private var timer: Timer?
    #if os(iOS)
    private let session = AudioSessionController()
    #endif

    func start() {
        #if os(iOS)
        session.onRouteChange = { [weak self] _ in
            // Multi-route drops Bluetooth/AirPlay, so choose the category per route.
            Task { @MainActor [weak self] in
                await self?.activateSession()
                self?.replan()
            }
        }
        session.onMediaServicesReset = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.activateSession()
                self?.rebuild()
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.activateSession()
            self.rebuild()
            self.startTimer()
        }
        #else
        rebuild()
        startTimer()
        #endif
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    #if os(iOS)
    private func activateSession() async {
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
        do {
            try await session.activate(preferMultiRoute: AudioSessionController.multiRouteCandidate(ports))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    func rebuild() {
        #if os(iOS)
        let rate = session.sampleRate
        #else
        let rate = CoreAudioDevices.defaultOutputDevice().map(CoreAudioDevices.nominalSampleRate) ?? 48_000
        #endif
        host = EngineHost(sampleRate: rate > 0 ? rate : 48_000)
        masterTone = Self.pulseTrack(frequency: 220, offbeat: false, sampleRate: host!.sampleRate)
        cueTone = Self.pulseTrack(frequency: 880, offbeat: true, sampleRate: host!.sampleRate)
        replan()
    }

    func replan() {
        guard let host else { return }
        #if os(iOS)
        session.refreshOutputs()
        outputs = session.outputs
        let plan = RoutePlanner.plan(outputs: outputs, splitterCable: splitterCable, capabilities: .iOS)
        let channels = session.hardwareChannels
        let devices: (UInt32?, UInt32?) = (nil, nil)
        #else
        let found = CoreAudioDevices.outputDevices()
        outputs = found.map(\.port)
        let plan = RoutePlanner.plan(outputs: outputs, splitterCable: splitterCable, capabilities: .macOS,
                                     preferredMasterID: nil, preferredCueID: nil)
        let master = found.first { $0.port.id == plan.masterPort?.id }
        let cue = found.first { $0.port.id == plan.cuePort?.id }
        let channels = master?.port.channels ?? 2
        let devices: (UInt32?, UInt32?) = (master?.id, cue?.id)
        #endif
        self.plan = plan
        do {
            try host.start(plan: plan, hardwareChannels: channels, masterDevice: devices.0, cueDevice: devices.1)
            if playing { startSignals() }
        } catch {
            errorMessage = "Could not start audio: \(error.localizedDescription)"
        }
    }

    func togglePlay() {
        playing.toggle()
        playing ? startSignals() : stopSignals()
    }

    private func startSignals() {
        guard let host, let masterTone, let cueTone else { return }
        let e = host.engine
        host.load(masterTone, deck: 0)
        host.load(cueTone, deck: 1)
        sbe_engine_set_auto_gain(e, 0)
        sbe_mixer_set_crossfader(e, -1)       // deck A (master signal) to the crowd
        sbe_channel_set_cue(e, 1, 1)          // deck B pre-fader in headphones only
        sbe_mixer_set_cue_mix(e, 0)
        sbe_deck_play(e, 0)
        sbe_deck_play(e, 1)
    }

    private func stopSignals() {
        guard let e = host?.engine else { return }
        sbe_deck_pause(e, 0)
        sbe_deck_pause(e, 1)
    }

    private func poll() {
        guard let host else { return }
        let s = host.status()
        masterPeak = s.master_peak
        cuePeak = s.cue_peak
        cueUnderruns = s.cue_underruns
        host.collectGarbage()
    }

    /// 60 s of tone pulses at 120 BPM.
    static func pulseTrack(frequency: Double, offbeat: Bool, sampleRate: Double) -> Track {
        let frames = Int(sampleRate * 60)
        var data = [Float](repeating: 0, count: frames * 2)
        let beat = sampleRate * 0.5
        for i in 0..<frames {
            var t = Double(i).truncatingRemainder(dividingBy: beat)
            if offbeat { t = (Double(i) + beat / 2).truncatingRemainder(dividingBy: beat) }
            let env = t < sampleRate * 0.12 ? exp(-t / (sampleRate * 0.04)) : 0
            let v = Float(sin(2 * .pi * frequency * Double(i) / sampleRate) * env * 0.6)
            data[2 * i] = v
            data[2 * i + 1] = v
        }
        return Track(interleaved: data, channels: 2, sampleRate: sampleRate)!
    }
}
