import XCTest
@testable import SoundboardAudio
import SoundboardEngine

final class RoutePlannerTests: XCTestCase {
    func testFourChannelInterfaceUsesOneClock() {
        let ports = [OutputPort(id: "usb", name: "DJ Controller", kind: .usbAudio, channels: 4)]
        let plan = RoutePlanner.plan(outputs: ports, splitterCable: false, capabilities: .iOS)
        XCTAssertEqual(plan.topology, .multiChannel)
        XCTAssertEqual(plan.masterChannels.left, 0)
        XCTAssertEqual(plan.cueChannels.left, 2)
        XCTAssertTrue(plan.notices.isEmpty)
    }

    func testIOSMultiRouteUsbPlusHeadphones() {
        let ports = [
            OutputPort(id: "hp", name: "Headphones", kind: .wiredHeadphones, channels: 2, firstChannel: 0),
            OutputPort(id: "usb", name: "USB DAC", kind: .usbAudio, channels: 2, firstChannel: 2),
        ]
        let plan = RoutePlanner.plan(outputs: ports, splitterCable: false, capabilities: .iOS)
        XCTAssertEqual(plan.topology, .multiChannel)
        XCTAssertEqual(plan.masterPort?.id, "usb")
        XCTAssertEqual(plan.masterChannels.left, 2)
        XCTAssertEqual(plan.cueChannels.left, 0)
    }

    func testIOSCannotSplitSpeakerAndBluetooth() {
        let ports = [OutputPort(id: "bt", name: "AirPods", kind: .bluetoothA2DP, channels: 2, latency: 0.18)]
        let plan = RoutePlanner.plan(outputs: ports, splitterCable: false, capabilities: .iOS)
        XCTAssertEqual(plan.topology, .masterOnly)
        XCTAssertTrue(plan.notices.contains(.cueNeedsHardware))
        XCTAssertTrue(plan.notices.contains(.wirelessMasterLatency(milliseconds: 180)))
    }

    func testSplitterCable() {
        let ports = [OutputPort(id: "hp", name: "Headphone jack", kind: .wiredHeadphones, channels: 2)]
        let plan = RoutePlanner.plan(outputs: ports, splitterCable: true, capabilities: .iOS)
        XCTAssertEqual(plan.topology, .splitMono)
    }

    func testSplitterIgnoredOnSpeaker() {
        let ports = [OutputPort(id: "spk", name: "Speaker", kind: .builtInSpeaker, channels: 2)]
        let plan = RoutePlanner.plan(outputs: ports, splitterCable: true, capabilities: .iOS)
        XCTAssertEqual(plan.topology, .masterOnly)
    }

    func testMacSeparateDevicesWithLatencyAlignment() {
        let ports = [
            OutputPort(id: "bt", name: "Party speaker", kind: .bluetoothA2DP, channels: 2, latency: 0.200),
            OutputPort(id: "hp", name: "Headphones", kind: .wiredHeadphones, channels: 2, latency: 0.012),
        ]
        let plan = RoutePlanner.plan(outputs: ports, splitterCable: false, capabilities: .macOS)
        XCTAssertEqual(plan.topology, .separateCueDevice)
        XCTAssertEqual(plan.masterPort?.id, "bt")
        XCTAssertEqual(plan.cuePort?.id, "hp")
        XCTAssertEqual(plan.cueDelay, 0.188, accuracy: 1e-9)
        XCTAssertEqual(plan.masterDelay, 0)
    }

    func testCueSlowerThanMasterIsReportedNotHidden() {
        let ports = [
            OutputPort(id: "usb", name: "Interface", kind: .usbAudio, channels: 2, latency: 0.008),
            OutputPort(id: "bt", name: "BT headphones", kind: .bluetoothA2DP, channels: 2, latency: 0.180),
        ]
        let plan = RoutePlanner.plan(outputs: ports, splitterCable: false, capabilities: .macOS, preferredCueID: "bt")
        XCTAssertEqual(plan.masterDelay, 0, "the crowd's output is never delayed for the DJ's headphones")
        XCTAssertTrue(plan.notices.contains(.cueSlowerThanMaster(milliseconds: 172)))
    }

    func testEngineLinksAndRenders() {
        let host = EngineHost(sampleRate: 48_000, maxBlock: 256)
        var tone = [Float](repeating: 0, count: 48_000 * 2)
        for i in 0..<48_000 { let v = Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) * 0.5; tone[2 * i] = v; tone[2 * i + 1] = v }
        let track = Track(interleaved: tone, channels: 2, sampleRate: 48_000)!
        host.load(track, deck: 0)
        sbe_deck_play(host.engine, 0)
        sbe_mixer_set_crossfader(host.engine, -1)
        var l = [Float](repeating: 0, count: 512), r = [Float](repeating: 0, count: 512)
        var peak: Float = 0
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                var ptrs: [UnsafeMutablePointer<Float>?] = [lp.baseAddress, rp.baseAddress]
                for _ in 0..<20 { sbe_engine_render(host.engine, &ptrs, 2, 512) }
                peak = lp.max() ?? 0
            }
        }
        XCTAssertGreaterThan(peak, 0.4)
    }
}
