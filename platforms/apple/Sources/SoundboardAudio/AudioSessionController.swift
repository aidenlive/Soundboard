#if os(iOS)
import AVFAudio
import Foundation

/// Owns the iOS audio session: category, buffer size, route discovery and route-change handling.
///
/// iOS facts this is built around (see docs/research/platform-audio.md):
///  * `.playback` routes to the last-connected output only — one stereo pair.
///  * `.multiRoute` exposes USB / HDMI / line-out together with wired headphones as one aggregate
///    stream whose channels map to ports. It does not include the built-in speaker, Bluetooth
///    or AirPlay, so a phone alone cannot play master on its speaker and cue in AirPods.
///  * A class-compliant USB interface with ≥ 4 outputs appears as one multichannel port.
///  * The hardware volume buttons scale the whole output; the engine never relies on them.
@MainActor
public final class AudioSessionController {
    public private(set) var outputs: [OutputPort] = []
    public var onRouteChange: (([OutputPort]) -> Void)?
    public var onInterruption: ((_ began: Bool) -> Void)?
    public var onMediaServicesReset: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Configure for low-latency playback. `multiRoute` is used only when a second output exists.
    public func activate(preferMultiRoute: Bool, preferredSampleRate: Double = 48_000,
                         preferredBuffer: TimeInterval = 0.005) throws {
        let category: AVAudioSession.Category = preferMultiRoute ? .multiRoute : .playback
        try session.setCategory(category, mode: .default, options: [])
        try session.setPreferredSampleRate(preferredSampleRate)
        try session.setPreferredIOBufferDuration(preferredBuffer)
        try session.setActive(true)
        // Ask for every channel the route offers (e.g. 4 on a DJ controller).
        let maxChannels = session.maximumOutputNumberOfChannels
        if maxChannels > session.outputNumberOfChannels {
            try? session.setPreferredOutputNumberOfChannels(maxChannels)
        }
        refreshOutputs()
        installObservers()
    }

    public var sampleRate: Double { session.sampleRate }
    public var ioBufferDuration: TimeInterval { session.ioBufferDuration }
    public var hardwareChannels: Int { session.outputNumberOfChannels }

    /// Ports of the current route, with each port's first channel in the hardware stream.
    public func refreshOutputs() {
        var firstChannel = 0
        var result: [OutputPort] = []
        let routeLatency = session.outputLatency + session.ioBufferDuration
        for port in session.currentRoute.outputs {
            let channels = port.channels?.count ?? 2
            result.append(OutputPort(id: port.uid, name: port.portName, kind: Self.kind(of: port.portType),
                                     channels: channels, latency: routeLatency, firstChannel: firstChannel))
            firstChannel += channels
        }
        outputs = result
    }

    /// True when the connected hardware makes `.multiRoute` worthwhile (USB/HDMI/line + headphones).
    public static func multiRouteCandidate(_ ports: [AVAudioSessionPortDescription]) -> Bool {
        let kinds = Set(ports.map { kind(of: $0.portType) })
        return kinds.contains(.wiredHeadphones) && !kinds.isDisjoint(with: [.usbAudio, .hdmi, .lineOut])
    }

    static func kind(of type: AVAudioSession.Port) -> OutputPort.Kind {
        switch type {
        case .builtInSpeaker, .builtInReceiver: .builtInSpeaker
        case .headphones: .wiredHeadphones
        case .usbAudio: .usbAudio
        case .lineOut: .lineOut
        case .HDMI, .displayPort: .hdmi
        case .bluetoothA2DP: .bluetoothA2DP
        case .bluetoothLE, .bluetoothHFP: .bluetoothLE
        case .airPlay: .airPlay
        case .carAudio: .carAudio
        default: .other
        }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Route changes can invalidate a multi-route channel map: always re-plan.
                self.refreshOutputs()
                self.onRouteChange?(self.outputs)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                self?.onInterruption?(raw == AVAudioSession.InterruptionType.began.rawValue)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMediaServicesReset?() }
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }
}
#endif
