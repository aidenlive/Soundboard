#if os(macOS)
import CoreAudio
import Foundation

/// Enumerates Core Audio output devices on macOS.
///
/// macOS has no audio-session routing restrictions: any number of devices can run at once,
/// each on its own clock. The engine therefore either uses one multichannel device (single clock,
/// preferred) or runs the cue bus on a second device through the drift-compensated FIFO
/// (`SBE_TOPOLOGY_SEPARATE_CUE_DEVICE`). Users can also build an aggregate device in Audio MIDI
/// Setup; it then appears here as one multichannel device.
public enum CoreAudioDevices {
    public struct Device: Hashable, Sendable {
        public var id: AudioDeviceID
        public var port: OutputPort
    }

    public static func outputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            let channels = outputChannelCount(id)
            // Skip virtual/aggregate-by-app devices (BlackHole, Loopback, conferencing drivers):
            // they often report 16+ channels and would be mistaken for a DJ interface.
            guard channels > 0, transportType(id) != kAudioDeviceTransportTypeVirtual else { return nil }
            let port = OutputPort(id: uid(id) ?? "\(id)", name: name(id) ?? "Device \(id)",
                                  kind: kind(id), channels: channels, latency: outputLatency(id))
            return Device(id: id, port: port)
        }
    }

    public static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    public static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var rate = Float64(0)
        _ = get(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate)
        return rate
    }

    /// Sets the device's I/O buffer size in frames (clamped by the device). Returns the size in effect.
    @discardableResult
    public static func setBufferFrameSize(_ id: AudioDeviceID, frames: UInt32) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = frames
        _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return bufferFrameSize(id)
    }

    public static func bufferFrameSize(_ id: AudioDeviceID) -> UInt32 {
        var frames: UInt32 = 0
        _ = get(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, &frames)
        return frames
    }

    static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Device + stream latency + safety offset + one buffer, in seconds.
    static func outputLatency(_ id: AudioDeviceID) -> TimeInterval {
        var device: UInt32 = 0, safety: UInt32 = 0, buffer: UInt32 = 0
        _ = get(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, &device)
        _ = get(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &safety)
        _ = get(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, &buffer)
        let rate = nominalSampleRate(id)
        guard rate > 0 else { return 0 }
        return Double(device + safety + buffer) / rate
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var transport: UInt32 = 0
        _ = get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &transport)
        return transport
    }

    static func kind(_ id: AudioDeviceID) -> OutputPort.Kind {
        switch transportType(id) {
        case kAudioDeviceTransportTypeUSB: return .usbAudio
        case kAudioDeviceTransportTypeBluetooth: return .bluetoothA2DP
        case kAudioDeviceTransportTypeBluetoothLE: return .bluetoothLE
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .hdmi
        case kAudioDeviceTransportTypeBuiltIn:
            // Built-in output is either the speakers or the headphone jack depending on data source.
            var source: UInt32 = 0
            _ = get(id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, &source)
            return source == 0x6864_706E /* 'hdpn' */ ? .wiredHeadphones : .builtInSpeaker
        default: return .other
        }
    }

    static func name(_ id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }
    static func uid(_ id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Reads a fixed-size numeric property (UInt32, Float64). Constrained to numeric types so no object reference can be written through the raw pointer.
    private static func get<T: Numeric>(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                        _ scope: AudioObjectPropertyScope, _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
    }
}
#endif
