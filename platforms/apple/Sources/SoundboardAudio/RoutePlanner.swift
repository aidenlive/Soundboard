import Foundation

/// A physical output the platform reports (an AVAudioSession port on iOS, a Core Audio device on macOS).
public struct OutputPort: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case builtInSpeaker, wiredHeadphones, usbAudio, lineOut, hdmi
        case bluetoothA2DP, bluetoothLE, airPlay, carAudio, other

        /// Wireless paths add codec + radio latency that DJs can hear.
        public var isWireless: Bool { self == .bluetoothA2DP || self == .bluetoothLE || self == .airPlay }
        /// Outputs that usually feed a sound system rather than the DJ's ears.
        public var isVenueOutput: Bool {
            switch self {
            case .usbAudio, .lineOut, .hdmi, .builtInSpeaker, .bluetoothA2DP, .bluetoothLE, .airPlay, .carAudio: true
            default: false
            }
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var channels: Int
    /// Output latency in seconds as reported by the OS (hardware + buffering + codec).
    public var latency: TimeInterval
    /// Index of this port's first channel within the hardware stream (iOS multi-route aggregates).
    public var firstChannel: Int

    public init(id: String, name: String, kind: Kind, channels: Int, latency: TimeInterval = 0, firstChannel: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.channels = channels
        self.latency = latency
        self.firstChannel = firstChannel
    }
}

/// Mirrors `sbe_topology`.
public enum CueTopology: Int, Sendable {
    case masterOnly = 0, splitMono = 1, multiChannel = 2, separateCueDevice = 3
}

public struct RoutePlan: Equatable, Sendable {
    public var topology: CueTopology
    public var masterPort: OutputPort?
    public var cuePort: OutputPort?
    /// Hardware channel indices (within the master device's stream) for each bus.
    public var masterChannels: (left: Int, right: Int)
    public var cueChannels: (left: Int, right: Int)
    /// Delay applied to each bus so both paths line up in the DJ's ears.
    public var masterDelay: TimeInterval
    public var cueDelay: TimeInterval
    public var notices: [Notice]

    public enum Notice: Equatable, Sendable {
        case cueNeedsHardware
        case wirelessMasterLatency(milliseconds: Int)
        case wirelessCueLatency(milliseconds: Int)
        case airPlayNotForLiveMixing
        case cueSlowerThanMaster(milliseconds: Int)
    }

    public var cueAvailable: Bool { topology != .masterOnly }

    public static func == (a: RoutePlan, b: RoutePlan) -> Bool {
        a.topology == b.topology && a.masterPort == b.masterPort && a.cuePort == b.cuePort
            && a.masterChannels == b.masterChannels && a.cueChannels == b.cueChannels
            && a.masterDelay == b.masterDelay && a.cueDelay == b.cueDelay && a.notices == b.notices
    }
}

/// Decides how master and cue reach the hardware. Pure logic, shared semantics with the Android
/// `RoutePlanner.kt`, unit-tested on both platforms.
///
/// Preference order (best first):
///   1. One device with ≥ 4 outputs (USB interface / DJ controller): master + cue on one clock.
///   2. Two simultaneously usable outputs: iOS multi-route aggregate (one stream, channel map),
///      or two independent devices on macOS (drift-compensated cue stream).
///   3. A stereo/mono splitter cable on a wired output: mono master + mono cue.
///   4. Master only: cueing in headphones is not possible without hardware — say so plainly.
public enum RoutePlanner {
    public struct Capabilities: Sendable {
        /// iOS `.multiRoute`: the OS exposes several ports as one aggregate stream.
        public var aggregatesPorts: Bool
        /// macOS: independent devices may run concurrently (separate clocks).
        public var concurrentDevices: Bool
        public init(aggregatesPorts: Bool, concurrentDevices: Bool) {
            self.aggregatesPorts = aggregatesPorts
            self.concurrentDevices = concurrentDevices
        }
        public static let iOS = Capabilities(aggregatesPorts: true, concurrentDevices: false)
        public static let macOS = Capabilities(aggregatesPorts: false, concurrentDevices: true)
    }

    public static func plan(outputs: [OutputPort], splitterCable: Bool, capabilities: Capabilities,
                            preferredMasterID: String? = nil, preferredCueID: String? = nil) -> RoutePlan {
        var notices: [RoutePlan.Notice] = []
        let pick: (String?) -> OutputPort? = { id in id.flatMap { id in outputs.first { $0.id == id } } }

        // 1. Multichannel interface.
        if let multi = pick(preferredMasterID).flatMap({ $0.channels >= 4 ? $0 : nil })
            ?? outputs.filter({ $0.channels >= 4 && !$0.kind.isWireless }).max(by: { $0.channels < $1.channels }) {
            let base = multi.firstChannel
            return RoutePlan(topology: .multiChannel, masterPort: multi, cuePort: multi,
                             masterChannels: (base, base + 1), cueChannels: (base + 2, base + 3),
                             masterDelay: 0, cueDelay: 0, notices: notices)
        }

        // 2. Two outputs at once: venue output for master, headphones for cue.
        let headphones = pick(preferredCueID) ?? outputs.first { $0.kind == .wiredHeadphones }
            ?? outputs.first { $0.kind == .usbAudio && $0.name.localizedCaseInsensitiveContains("headphone") }
        let venue = pick(preferredMasterID) ?? outputs
            .filter { $0.id != headphones?.id && $0.kind.isVenueOutput }
            .sorted { rank($0.kind) < rank($1.kind) }
            .first
        if let cue = headphones, let master = venue, cue.id != master.id {
            let canAggregate = capabilities.aggregatesPorts && aggregatable(master.kind) && cue.kind == .wiredHeadphones
            let canSeparate = capabilities.concurrentDevices
            if canAggregate || canSeparate {
                appendWirelessNotices(master: master, cue: cue, into: &notices)
                let (md, cd) = alignment(master: master, cue: cue, notices: &notices)
                if canAggregate {
                    return RoutePlan(topology: .multiChannel, masterPort: master, cuePort: cue,
                                     masterChannels: (master.firstChannel, master.firstChannel + min(1, master.channels - 1)),
                                     cueChannels: (cue.firstChannel, cue.firstChannel + min(1, cue.channels - 1)),
                                     masterDelay: md, cueDelay: cd, notices: notices)
                }
                return RoutePlan(topology: .separateCueDevice, masterPort: master, cuePort: cue,
                                 masterChannels: (0, min(1, master.channels - 1)),
                                 cueChannels: (0, min(1, cue.channels - 1)),
                                 masterDelay: md, cueDelay: cd, notices: notices)
            }
        }

        // 3. Splitter cable on a single wired stereo output.
        let primary = pick(preferredMasterID) ?? outputs.first
        if splitterCable, let out = primary, !out.kind.isWireless, out.kind != .builtInSpeaker, out.channels >= 2 {
            return RoutePlan(topology: .splitMono, masterPort: out, cuePort: out,
                             masterChannels: (out.firstChannel, out.firstChannel),
                             cueChannels: (out.firstChannel + 1, out.firstChannel + 1),
                             masterDelay: 0, cueDelay: 0, notices: notices)
        }

        // 4. Master only.
        notices.append(.cueNeedsHardware)
        if let out = primary { appendWirelessNotices(master: out, cue: nil, into: &notices) }
        return RoutePlan(topology: .masterOnly, masterPort: primary, cuePort: nil,
                         masterChannels: (primary?.firstChannel ?? 0, (primary?.firstChannel ?? 0) + 1),
                         cueChannels: (0, 0), masterDelay: 0, cueDelay: 0, notices: notices)
    }

    /// Ports iOS multi-route can combine with headphones (per Apple's multiroute documentation).
    static func aggregatable(_ kind: OutputPort.Kind) -> Bool {
        kind == .usbAudio || kind == .hdmi || kind == .lineOut
    }

    static func rank(_ kind: OutputPort.Kind) -> Int {
        switch kind {
        case .usbAudio: 0
        case .lineOut: 1
        case .hdmi: 2
        case .bluetoothLE: 3
        case .bluetoothA2DP: 4
        case .builtInSpeaker: 5
        case .carAudio: 6
        case .airPlay: 7
        default: 8
        }
    }

    static func appendWirelessNotices(master: OutputPort, cue: OutputPort?, into notices: inout [RoutePlan.Notice]) {
        if master.kind == .airPlay { notices.append(.airPlayNotForLiveMixing) }
        else if master.kind.isWireless { notices.append(.wirelessMasterLatency(milliseconds: Int((master.latency * 1000).rounded()))) }
        if let cue, cue.kind.isWireless { notices.append(.wirelessCueLatency(milliseconds: Int((cue.latency * 1000).rounded()))) }
    }

    /// Delay the faster path so the DJ hears master and cue in time. The master is never
    /// delayed to wait for a slow headphone path — the crowd's timing matters more — the
    /// mismatch is reported instead.
    static func alignment(master: OutputPort, cue: OutputPort, notices: inout [RoutePlan.Notice]) -> (TimeInterval, TimeInterval) {
        let diff = master.latency - cue.latency
        if diff > 0.002 { return (0, diff) }
        if diff < -0.010 { notices.append(.cueSlowerThanMaster(milliseconds: Int((-diff * 1000).rounded()))) }
        return (0, 0)
    }
}
