import AudioToolbox
import AVFAudio
import Foundation
@_exported import SoundboardEngine

/// Connects the shared C++ engine to Apple audio hardware.
///
/// Uses `AUAudioUnit` output units directly (RemoteIO on iOS, HAL output on macOS) rather than
/// `AVAudioEngine`: the engine already does its own mixing, and a raw output unit gives exact
/// control of channel count, device binding and buffer size with nothing in between.
public final class EngineHost: @unchecked Sendable {
    /// `sbe_engine*` — pass to any `sbe_*` C function.
    public let engine: OpaquePointer
    public let sampleRate: Double
    private var masterUnit: OutputUnit?
    private var cueUnit: OutputUnit?
    public private(set) var plan: RoutePlan?

    public init(sampleRate: Double, maxBlock: Int = 1024, decks: Int = 2) {
        self.sampleRate = sampleRate
        guard let e = sbe_engine_create(sampleRate, Int32(maxBlock), Int32(decks)) else {
            fatalError("sbe_engine_create failed")
        }
        engine = e
    }

    deinit {
        stop()
        sbe_engine_destroy(engine)
    }

    /// Applies a route plan to the engine and starts the hardware.
    /// - Parameters:
    ///   - hardwareChannels: channel count of the master stream (iOS: session output channels).
    ///   - masterDevice / cueDevice: Core Audio device IDs (macOS only; ignored on iOS).
    public func start(plan: RoutePlan, hardwareChannels: Int,
                      masterDevice: UInt32? = nil, cueDevice: UInt32? = nil) throws {
        stop()
        self.plan = plan
        sbe_engine_set_output_layout(engine, sbe_topology(rawValue: UInt32(plan.topology.rawValue)),
                                     Int32(plan.masterChannels.left), Int32(plan.masterChannels.right),
                                     Int32(plan.cueChannels.left), Int32(plan.cueChannels.right))
        sbe_engine_set_latency_compensation(engine, Int32((plan.masterDelay * sampleRate).rounded()),
                                            Int32((plan.cueDelay * sampleRate).rounded()))
        let engine = self.engine
        masterUnit = try OutputUnit(deviceID: masterDevice, channels: max(1, hardwareChannels), sampleRate: sampleRate) {
            ptrs, channels, frames in sbe_engine_render(engine, ptrs, channels, frames)
        }
        if plan.topology == .separateCueDevice {
            #if os(macOS)
            let cueChannels = max(1, min(2, plan.cuePort?.channels ?? 2))
            cueUnit = try OutputUnit(deviceID: cueDevice, channels: cueChannels, sampleRate: sampleRate) {
                ptrs, channels, frames in sbe_engine_render_cue(engine, ptrs, channels, frames)
            }
            #endif
        }
        try masterUnit?.start()
        try cueUnit?.start()
    }

    public func stop() {
        cueUnit?.stop()
        masterUnit?.stop()
        cueUnit = nil
        masterUnit = nil
    }

    /// Call periodically (e.g. from the UI refresh) to free tracks the audio thread released.
    public func collectGarbage() { sbe_engine_collect_garbage(engine) }

    public func status() -> sbe_engine_status {
        var s = sbe_engine_status()
        sbe_engine_get_status(engine, &s)
        return s
    }

    public func deckStatus(_ deck: Int) -> sbe_deck_status {
        var s = sbe_deck_status()
        sbe_deck_get_status(engine, Int32(deck), &s)
        return s
    }
}

/// One hardware output stream driven by a render closure on the real-time thread.
final class OutputUnit {
    typealias Render = (UnsafePointer<UnsafeMutablePointer<Float>?>, Int32, Int32) -> Void
    private static let maxChannels = 64

    let unit: AUAudioUnit
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    init(deviceID: UInt32?, channels: Int, sampleRate: Double, render: @escaping Render) throws {
        #if os(iOS)
        let subtype = kAudioUnitSubType_RemoteIO
        #else
        let subtype = kAudioUnitSubType_HALOutput
        #endif
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: subtype,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        // Configure a local first: `self` may not be touched until every stored property is set.
        let au = try AUAudioUnit(componentDescription: desc)
        #if os(macOS)
        if let deviceID { try au.setDeviceID(deviceID) }
        #endif
        let count = min(channels, Self.maxChannels)
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(count)) else {
            throw NSError(domain: "Soundboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "channel layout"])
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
        try au.inputBusses[0].setFormat(format)
        au.maximumFramesToRender = 4096

        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: Self.maxChannels)
        ptrs.initialize(repeating: nil, count: Self.maxChannels)
        let maxCh = Self.maxChannels
        // Real-time block: no allocation, no locks, no Objective-C messaging — pointer setup + C call.
        au.outputProvider = { _, _, frameCount, _, bufferList in
            let list = UnsafeMutableAudioBufferListPointer(bufferList)
            let n = min(list.count, maxCh)
            for i in 0..<n {
                guard let data = list[i].mData else {
                    for j in 0..<list.count { if let d = list[j].mData { memset(d, 0, Int(list[j].mDataByteSize)) } }
                    return noErr
                }
                ptrs[i] = data.assumingMemoryBound(to: Float.self)
            }
            render(UnsafePointer(ptrs), Int32(n), Int32(frameCount))
            for j in n..<list.count { if let d = list[j].mData { memset(d, 0, Int(list[j].mDataByteSize)) } }
            return noErr
        }
        do {
            try au.allocateRenderResources()
        } catch {
            ptrs.deallocate()
            throw error
        }
        unit = au
        channelPointers = ptrs
    }

    func start() throws { try unit.startHardware() }
    func stop() { unit.stopHardware() }

    deinit {
        unit.stopHardware()
        unit.deallocateRenderResources()
        channelPointers.deallocate()
    }
}
