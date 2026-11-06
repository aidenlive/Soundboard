import SwiftUI
import SoundboardAudio

/// Advanced deck controls, shown only when asked for (progressive disclosure):
/// - Quick view: the record button opens this as a sheet for the deck in focus.
/// - Mix view: the DJ layout shows the jog and pitch inline, and Loop/FX in a strip.
/// - Anywhere: tapping a deck's BPM opens the tempo popover; the loop button's menu has every size.
@MainActor
struct DeckToolsPanel: View {
    @Bindable var session: DJSession
    let index: Int
    @State private var tab: Tab = .jog
    @Environment(\.obsidian) private var t
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case jog, loop, cues, fx
        var id: String { rawValue }
        var title: String {
            switch self {
            case .jog: "JOG"
            case .loop: "LOOP"
            case .cues: "CUES"
            case .fx: "FX"
            }
        }
    }

    var body: some View {
        let d = session.decks[index]
        VStack(spacing: t.gap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow("Deck \(d.letter)")
                    Text(d.loaded ? d.title : "No track").font(t.ui(17, .semibold)).foregroundStyle(t.text)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.bpm(d.effectiveBpm)).font(t.mono(22, .medium)).monospacedDigit().foregroundStyle(t.text)
                    Text(Format.tempo(d.tempo)).font(t.mono(10)).monospacedDigit().foregroundStyle(t.textMuted)
                }
                .fixedSize()
                Button("DONE") { dismiss() }.buttonStyle(ObsidianButtonStyle())
            }
            Segmented(Tab.allCases.map { ($0, $0.title) }, selection: $tab)
            Group {
                switch tab {
                case .jog: JogSection(session: session, index: index)
                case .loop: LoopSection(session: session, index: index)
                case .cues: PadGrid(session: session, deck: index)
                case .fx: EchoSection(session: session, index: index)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(t.pad)
        .background(t.background)
        .disabled(!d.loaded)
    }
}

/// Jog wheel, pitch fader and nudge.
@MainActor
struct JogSection: View {
    let session: DJSession
    let index: Int
    var compact = false
    @Environment(\.obsidian) private var t

    var body: some View {
        let d = session.decks[index]
        let c = session.preferences.prefs.controller
        HStack(alignment: .center, spacing: compact ? 8 : 14) {
            if index == 1 { pitch(d) }
            JogWheel(deck: d, vinylMode: c.vinylMode,
                     touch: { session.jogTouch(index, $0) },
                     scratch: { session.jogScratch(index, revolutions: $0) },
                     bend: { session.jogBend(index, revolutions: $0) })
                .frame(maxWidth: compact ? 220 : 320)
                .layoutPriority(1)
            if index == 0 { pitch(d) }
        }
    }

    private func pitch(_ d: DeckState) -> some View {
        VStack(spacing: 6) {
            PitchFader(tempo: d.tempo, range: session.pitchRange) { session.setTempo(index, $0) }
                .frame(width: 44)
                .frame(minHeight: 120, maxHeight: compact ? 180 : 240)
            NudgeButtons { session.nudge(index, $0) }.frame(width: 76)
            Button { session.sync(index) } label: { Text(d.syncLocked ? "SYNC ●" : "SYNC").frame(maxWidth: .infinity) }
                .buttonStyle(ObsidianButtonStyle(prominent: d.syncLocked))
                .frame(width: 76)
        }
    }
}

/// Beat loops (¼ to 32 beats), halve/double, reloop and beat jump.
@MainActor
struct LoopSection: View {
    let session: DJSession
    let index: Int
    var compact = false
    @Environment(\.obsidian) private var t

    static let sizes: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]

    var body: some View {
        let d = session.decks[index]
        let current = d.loopActive ? loopBeats(d) : nil
        VStack(alignment: .leading, spacing: 8) {
            if !compact { Eyebrow("Beat loop") }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: compact ? 8 : 4), spacing: 4) {
                ForEach(Self.sizes, id: \.self) { b in
                    let on = current.map { abs($0 - b) < 0.01 } ?? false
                    Button {
                        if on { session.exitLoop(index) } else { session.setBeatLoop(index, beats: b) }
                    } label: {
                        Text(Self.label(b)).font(t.mono(compact ? 10 : 12, .medium))
                            .frame(maxWidth: .infinity, minHeight: compact ? 30 : 40)
                            .foregroundStyle(on ? t.onPrimary : t.text)
                            .background(on ? t.primary : t.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(t.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Loop \(Self.label(b)) beats")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack(spacing: 4) {
                small("½×", "Halve loop") { session.scaleLoop(index, 0.5) }.disabled(!d.loopActive)
                small("2×", "Double loop") { session.scaleLoop(index, 2) }.disabled(!d.loopActive)
                small(d.loopActive ? "EXIT" : "RELOOP", d.loopActive ? "Exit loop" : "Reloop") {
                    if d.loopActive { session.exitLoop(index) } else { session.reloop(index) }
                }
                .disabled(!d.loopActive && d.loopOut <= d.loopIn)
            }
            if !compact { Eyebrow("Beat jump") }
            HStack(spacing: 4) {
                ForEach([-16.0, -4, -1, 1, 4, 16], id: \.self) { b in
                    small(b < 0 ? "◀\(Int(-b))" : "\(Int(b))▶", "Jump \(b < 0 ? "back" : "forward") \(Int(abs(b))) beats") {
                        session.beatJump(index, beats: b)
                    }
                }
            }
        }
    }

    static func label(_ b: Double) -> String {
        switch b {
        case 0.25: "¼"
        case 0.5: "½"
        default: "\(Int(b))"
        }
    }

    private func loopBeats(_ d: DeckState) -> Double? {
        guard d.bpm > 0, d.loopOut > d.loopIn else { return nil }
        return (d.loopOut - d.loopIn) / (60 / d.bpm * d.sampleRate)
    }

    private func small(_ text: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(t.mono(compact ? 10 : 11, .medium)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: compact ? 30 : 36)
                .foregroundStyle(t.text)
                .background(t.surface)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(t.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Beat-synced echo on the channel.
@MainActor
struct EchoSection: View {
    let session: DJSession
    let index: Int
    var compact = false
    @Environment(\.obsidian) private var t

    static let lengths: [(Double, String)] = [(0.5, "½"), (0.75, "¾"), (1, "1"), (2, "2")]

    var body: some View {
        let d = session.decks[index]
        VStack(alignment: .leading, spacing: 8) {
            if !compact { Eyebrow("Echo") }
            HStack(spacing: 12) {
                Knob("Echo", value: Binding(get: { d.echoWet * 2 - 1 }, set: { session.setEcho(index, wet: max(0, ($0 + 1) / 2)) }),
                     valueText: d.echoWet <= 0.001 ? "off" : "\(Int(d.echoWet * 100)) %", size: compact ? 40 : 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text("BEATS").font(t.mono(10, .medium)).tracking(1).foregroundStyle(t.textMuted)
                    Segmented(Self.lengths, selection: Binding(get: { d.echoBeats }, set: { session.setEcho(index, wet: d.echoWet, beats: $0) }))
                }
            }
            if !compact {
                Text("Echo repeats in time with the track. Turn it down to let the tail ring out.")
                    .font(t.ui(12)).foregroundStyle(t.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Contextual tempo overlay (tap a deck's BPM): pitch, nudge, sync and the pitch range.
@MainActor
struct TempoPopover: View {
    @Bindable var session: DJSession
    let index: Int
    @Environment(\.obsidian) private var t

    var body: some View {
        let d = session.decks[index]
        let range = Binding(get: { session.preferences.prefs.mixing.pitchRange }, set: { session.preferences.prefs.mixing.pitchRange = $0 })
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("Tempo · deck \(d.letter)")
                Spacer(minLength: 8)
                Text(Format.bpm(d.effectiveBpm)).font(t.mono(20, .medium)).monospacedDigit().foregroundStyle(t.text)
            }
            HStack(alignment: .top, spacing: 14) {
                PitchFader(tempo: d.tempo, range: session.pitchRange) { session.setTempo(index, $0) }
                    .frame(width: 44, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    NudgeButtons { session.nudge(index, $0) }
                    Button { session.sync(index) } label: { Text(d.syncLocked ? "SYNC ●" : "SYNC").frame(maxWidth: .infinity) }
                        .buttonStyle(ObsidianButtonStyle(prominent: d.syncLocked))
                    Button { session.setTempo(index, 1) } label: { Text("RESET 0%").frame(maxWidth: .infinity) }
                        .buttonStyle(ObsidianButtonStyle())
                        .disabled(abs(d.tempo - 1) < 0.0005)
                    Text("RANGE").font(t.mono(10, .medium)).tracking(1).foregroundStyle(t.textMuted)
                    Segmented(MixingPrefs.pitchRangeChoices.map { ($0, "±\($0)") }, selection: range)
                }
                .frame(width: 180)
            }
        }
        .padding(t.pad)
        .background(t.background)
        .disabled(!d.loaded)
    }
}

/// Loop button with progressive disclosure: tap toggles a 4-beat loop; its menu has every size.
@MainActor
struct LoopButton: View {
    let session: DJSession
    let index: Int
    @Environment(\.obsidian) private var t

    var body: some View {
        let d = session.decks[index]
        Menu {
            ForEach(LoopSection.sizes, id: \.self) { b in
                Button("\(LoopSection.label(b)) beat\(b == 1 ? "" : "s")") { session.setBeatLoop(index, beats: b) }
            }
            Divider()
            Button("Halve") { session.scaleLoop(index, 0.5) }.disabled(!d.loopActive)
            Button("Double") { session.scaleLoop(index, 2) }.disabled(!d.loopActive)
            Button(d.loopActive ? "Exit loop" : "Reloop") {
                if d.loopActive { session.exitLoop(index) } else { session.reloop(index) }
            }
        } label: {
            Text("LOOP").font(t.mono(11, .semibold)).tracking(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(d.loopActive ? t.onPrimary : t.text)
                .background(d.loopActive ? t.primary : t.surface)
                .clipShape(RoundedRectangle(cornerRadius: t.radius))
                .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(t.border, lineWidth: 1))
        } primaryAction: {
            session.beatLoop(index, beats: 4)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(d.loopActive ? "Exit loop" : "Loop 4 beats")
        .accessibilityHint("Hold for other loop sizes")
    }
}
