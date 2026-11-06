import SwiftUI
import SoundboardAudio

/// Level 2–3 · Mix (landscape, iPad, Mac): both decks, aligned grids, pads, crossfader.
@MainActor
struct MixView: View {
    @Bindable var session: DJSession
    var roomy: Bool
    @Environment(\.obsidian) private var t
    @Environment(\.appActions) private var actions

    var body: some View {
        HStack(alignment: .top, spacing: t.gap) {
            DeckColumn(session: session, index: 0, roomy: roomy)
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    RouteChip(session: session).layoutPriority(1)
                    Spacer(minLength: 8)
                    SessionChip(session: session)
                    MixerMenu(session: session)
                    Button { actions.openLibrary() } label: { Image(systemName: "list.bullet") }
                        .buttonStyle(.plain).foregroundStyle(t.textSecondary).frame(width: 44, height: 32)
                        .accessibilityLabel("Library")
                    Button { actions.openSettings() } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.plain).foregroundStyle(t.textSecondary).frame(width: 44, height: 32)
                        .accessibilityLabel("Settings")
                }
                ForEach(0..<2, id: \.self) { i in
                    OverviewStrip(session.decks[i].visual, deck: session.decks[i].deck) { session.seek(i, frame: $0) }
                        .frame(height: 18)
                }
                decksArea
                    .frame(maxHeight: .infinity)
                HStack(alignment: .bottom, spacing: 12) {
                    PadGrid(session: session, deck: 0)
                    VStack(spacing: 6) {
                        Fader("Crossfader", value: $session.crossfader, leading: "A", trailing: "B")
                        MixControls(session: session, showPicker: roomy)
                    }
                    .frame(width: roomy ? 300 : 190)
                    PadGrid(session: session, deck: 1)
                }
            }
            .frame(maxWidth: .infinity)
            DeckColumn(session: session, index: 1, roomy: roomy)
        }
        .padding(t.pad)
    }

    @ViewBuilder private var decksArea: some View {
        switch t.appearance.deckView {
        case .linear:
            VStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { i in
                    DeckDisplay(deck: session.decks[i], secondsVisible: roomy ? 12 : 8)
                        .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
                }
            }
        case .radial:
            HStack(spacing: 20) {
                DeckDisplay(deck: session.decks[0], compactCenter: true)
                PhaseLock(a: session.decks[0], b: session.decks[1])
                DeckDisplay(deck: session.decks[1], compactCenter: true)
            }
        case .lanes:
            HStack(spacing: 2) {
                DeckDisplay(deck: session.decks[0], secondsVisible: 10)
                DeckDisplay(deck: session.decks[1], secondsVisible: 10)
            }
        }
    }
}

/// Deck info and transport at the side of the Mix view.
@MainActor
struct DeckColumn: View {
    let session: DJSession
    let index: Int
    var roomy: Bool
    @Environment(\.obsidian) private var t

    var body: some View {
        let d = session.decks[index]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("DECK \(d.letter)")
                Spacer(minLength: 2)
                Text(d.syncLocked ? "SYNC ●" : "SYNC ○").foregroundStyle(d.syncLocked ? t.primary : t.textMuted)
                DeckMenu(session: session, index: index)
            }
            .font(t.mono(10, .medium)).tracking(1).foregroundStyle(t.textMuted)
            Text(d.loaded ? d.title : "Empty").font(t.ui(13, .semibold)).lineLimit(2).foregroundStyle(t.text)
            Text(Format.bpm(d.effectiveBpm)).font(t.mono(26, .medium)).tracking(-1).foregroundStyle(t.text)
            Text("\(d.camelot.isEmpty ? "—" : d.camelot) · \(Format.tempo(d.tempo))").font(t.mono(10)).foregroundStyle(t.textMuted)
            if roomy {
                VStack(spacing: 10) {
                    KnobRow(session: session, deck: index, size: 40)
                }
                .padding(.vertical, 6)
                Fader("Channel \(d.letter) volume", value: Binding(get: { d.fader }, set: { session.set(.fader, deck: index, $0) }), in: 0...1)
            }
            Spacer(minLength: 0)
            transport(d)
        }
        .frame(width: roomy ? 220 : 120)
    }

    @ViewBuilder private func transport(_ d: DeckState) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { session.togglePlay(index) } label: { Image(systemName: d.playing ? "pause.fill" : "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(ObsidianButtonStyle(prominent: d.playing))
                    .accessibilityLabel(d.playing ? "Pause deck \(d.letter)" : "Play deck \(d.letter)")
                CueButton(session: session, index: index)
            }
            HStack(spacing: 6) {
                Button { session.sync(index) } label: { Text("SYNC").frame(maxWidth: .infinity) }
                    .buttonStyle(ObsidianButtonStyle())
                Button { session.setHeadphoneCue(index, !d.cueEnabled) } label: {
                    Image(systemName: "headphones").frame(maxWidth: .infinity)
                }
                .buttonStyle(ObsidianButtonStyle(prominent: d.cueEnabled))
                .disabled(!session.cueAvailable)
                .accessibilityLabel("Headphone cue deck \(d.letter)")
                .accessibilityValue(d.cueEnabled ? "on" : "off")
            }
        }
        .disabled(!d.loaded)
    }
}

/// CDJ-style cue: press = return to cue (or preview while held), release = back to cue.
@MainActor
struct CueButton: View {
    let session: DJSession
    let index: Int
    @State private var held = false
    @Environment(\.obsidian) private var t

    var body: some View {
        Text("CUE")
            .font(t.mono(11, .semibold)).tracking(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(t.text)
            .background(held ? t.surface2 : t.surface)
            .clipShape(RoundedRectangle(cornerRadius: t.radius))
            .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(t.border, lineWidth: 1))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !held { held = true; session.cuePress(index) } }
                .onEnded { _ in held = false; session.cueRelease(index) })
            .accessibilityElement()
            .accessibilityLabel("Cue deck \(index == 0 ? "A" : "B")")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { session.cuePress(index); session.cueRelease(index) }
    }
}

/// 8 hot-cue pads (tap: set or jump; long-press: clear) with cue-colour bars.
@MainActor
struct PadGrid: View {
    let session: DJSession
    let deck: Int
    @Environment(\.obsidian) private var t

    var body: some View {
        let cues = session.decks[deck].hotCues
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(0..<8, id: \.self) { n in
                let set = n < cues.count && cues[n] >= 0
                Button { session.hotCue(deck, n) } label: {
                    Text("\(n + 1)")
                        .font(t.mono(10, .medium))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(set ? t.text : t.textMuted)
                        .background(t.surface)
                        .overlay(alignment: .bottom) {
                            if set { Capsule().fill(t.cue(n)).frame(height: 2).padding(.horizontal, 4).padding(.bottom, 3) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(t.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if set { Button("Clear hot cue \(n + 1)", role: .destructive) { session.clearHotCue(deck, n) } }
                }
                .accessibilityLabel("Hot cue \(n + 1) deck \(deck == 0 ? "A" : "B")")
                .accessibilityValue(set ? "set" : "empty")
            }
        }
        .disabled(!session.decks[deck].loaded)
    }
}

/// Beat-by-beat phase display between the radial decks.
@MainActor
struct PhaseLock: View {
    let a: DeckState
    let b: DeckState
    @Environment(\.obsidian) private var t

    var body: some View {
        let ba = Int(floor(a.beat)) % 8, bb = Int(floor(b.beat)) % 8
        let locked = a.loaded && b.loaded && abs((a.beat - b.beat).remainder(dividingBy: 1)) < 0.02
        VStack(spacing: 3) {
            Text(locked ? "LOCKED" : "PHASE").font(t.mono(9, .medium)).tracking(1.2)
                .foregroundStyle(locked ? t.success : t.textMuted)
            ForEach(0..<8, id: \.self) { i in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1).fill(i <= ba ? t.text : t.surface2).frame(width: 12, height: 6)
                    RoundedRectangle(cornerRadius: 1).fill(i <= bb ? t.primary : t.surface2).frame(width: 12, height: 6)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(locked ? "Phase locked" : "Phase not locked")
    }
}
