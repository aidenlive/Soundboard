import SwiftUI
import SoundboardAudio

@main
struct RoutingLabApp: App {
    @State private var model = RoutingLabModel()

    var body: some Scene {
        WindowGroup {
            RoutingLabView(model: model)
                .task { model.start() }
        }
    }
}

struct RoutingLabView: View {
    @Bindable var model: RoutingLabModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Route") {
                    if let plan = model.plan {
                        LabeledContent("Cue mode", value: title(plan.topology))
                        LabeledContent("Master", value: plan.masterPort?.name ?? "—")
                        LabeledContent("Headphones", value: plan.cueAvailable ? (plan.cuePort?.name ?? "—") : "Unavailable")
                        if plan.cueDelay > 0 {
                            LabeledContent("Cue aligned by", value: "\(Int(plan.cueDelay * 1000)) ms")
                        }
                    }
                    Toggle("I'm using a stereo-to-mono splitter cable", isOn: $model.splitterCable)
                }
                if let notices = model.plan?.notices, !notices.isEmpty {
                    Section("Heads up") {
                        ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                            Label(text(notice), systemImage: "exclamationmark.triangle")
                        }
                    }
                }
                Section {
                    Button(model.playing ? "Stop test signals" : "Play test signals") { model.togglePlay() }
                    meter("Master (low pulse on the beat)", model.masterPeak)
                    meter("Headphones (high chirp off the beat)", model.cuePeak)
                    if model.cueUnderruns > 0 { Text("Cue underruns: \(model.cueUnderruns)").foregroundStyle(.red) }
                } footer: {
                    Text("Speakers should only ever play the low pulse. The high chirp must be audible in the headphones and nowhere else.")
                }
                Section("Outputs detected") {
                    ForEach(model.outputs) { port in
                        LabeledContent(port.name, value: "\(port.kind.rawValue) · \(port.channels) ch · \(Int(port.latency * 1000)) ms")
                    }
                }
                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Routing Lab")
        }
    }

    private func meter(_ label: String, _ value: Float) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption)
            ProgressView(value: Double(min(1, value)))
                .accessibilityValue("\(Int(value * 100)) percent")
        }
    }

    private func title(_ t: CueTopology) -> String {
        switch t {
        case .masterOnly: "Master only"
        case .splitMono: "Split cable (mono)"
        case .multiChannel: "Multichannel"
        case .separateCueDevice: "Separate headphone device"
        }
    }

    private func text(_ n: RoutePlan.Notice) -> String {
        switch n {
        case .cueNeedsHardware:
            "Private pre-listening needs a splitter cable, a USB audio interface or a DJ controller."
        case .wirelessMasterLatency(let ms):
            "Wireless master adds about \(ms) ms of delay. Fine for playback, but cueing against it will feel late."
        case .wirelessCueLatency(let ms):
            "Wireless headphones add about \(ms) ms of delay. Wired headphones are strongly recommended for cueing."
        case .airPlayNotForLiveMixing:
            "AirPlay buffers for around two seconds — not usable for live mixing."
        case .cueSlowerThanMaster(let ms):
            "Your headphones are \(ms) ms behind the speakers; the speakers are never delayed to compensate."
        }
    }
}
