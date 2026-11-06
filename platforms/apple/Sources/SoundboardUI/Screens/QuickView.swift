import SwiftUI
import SoundboardAudio

/// Level 1 · Quick Control (phone portrait): one deck in focus, the next track suggested,
/// and a single Mix action.
@MainActor
struct QuickView: View {
    @Bindable var session: DJSession
    @Environment(\.obsidian) private var t
    @Environment(\.appActions) private var actions
    @Environment(\.layout) private var layout
    @State private var tempoOpen = false

    var body: some View {
        let i = session.focusDeck
        let deck = session.decks[i]
        VStack(spacing: t.gap) {
            header
            if !deck.loaded {
                EmptyDeckView(session: session)
            } else {
                OverviewStrip(deck.visual, deck: deck.deck) { session.seek(i, frame: $0) }
                    .frame(height: 26)
                    .padding(.horizontal, t.pad)
                ZStack(alignment: .topLeading) {
                    DeckDisplay(deck: deck)
                        .frame(height: deckHeight)
                        .frame(maxWidth: .infinity)
                    if t.appearance.deckView != .radial {
                        phraseBadge(deck).padding(.leading, 12).padding(.top, 8)
                    }
                }
                trackInfo(deck)
                upNext
                MixControls(session: session, showPicker: !layout.shortPortrait).padding(.horizontal, t.pad)
                // Short phones keep the knobs one tap away (Deck tools › EQ) instead of clipping them.
                if !layout.shortPortrait {
                    KnobRow(session: session, deck: i, size: layout.narrow ? 44 : 52).padding(.horizontal, t.pad)
                }
                Spacer(minLength: 0)
                footer(i)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// The deck takes what the rest leaves: 30 % of the height, between 140 and 290 pt.
    private var deckHeight: CGFloat {
        let share = layout.size.height * (layout.shortPortrait ? 0.24 : 0.30)
        let cap: CGFloat = t.appearance.deckView == .radial ? 290 : 240
        return min(cap, max(140, share))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                SessionChip(session: session)
                Spacer(minLength: 8)
                Button { actions.openSettings() } label: {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(t.textSecondary).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            RouteChip(session: session)
        }
        .padding(.horizontal, t.pad)
    }

    private func phraseBadge(_ d: DeckState) -> some View {
        Text("PHRASE IN \(PhraseClock.barsToNextPhrase(atBeat: d.beat)) BARS")
            .font(t.mono(10, .medium)).tracking(1)
            .foregroundStyle(t.onPrimary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(t.primary)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func trackInfo(_ d: DeckState) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).font(t.ui(layout.narrow ? 17 : 20, .semibold)).oneLine()
                Text(d.artist.isEmpty ? " " : d.artist).font(t.ui(13)).foregroundStyle(t.textMuted).oneLine()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DeckMenu(session: session, index: d.index)
            Button { tempoOpen = true } label: {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Format.bpm(d.effectiveBpm)).font(t.mono(layout.narrow ? 28 : 34, .medium)).tracking(-1).readout()
                    Text("\(d.camelot.isEmpty ? "—" : d.camelot) · −\(Format.time(d.remaining))").font(t.mono(11)).foregroundStyle(t.textMuted).readout()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tempo \(Format.bpm(d.effectiveBpm)) BPM")
            .accessibilityHint("Opens pitch, nudge and sync")
            .popover(isPresented: $tempoOpen) {
                TempoPopover(session: session, index: d.index).presentationCompactAdaptation(.popover)
            }
        }
        .foregroundStyle(t.text)
        .padding(.horizontal, t.pad)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var upNext: some View {
        let other = session.decks[1 - session.focusDeck]
        let suggestion = session.upNext.first
        Button { actions.openLibrary() } label: {
            HStack(spacing: 12) {
                Text("NEXT").font(t.mono(10, .medium)).tracking(1).foregroundStyle(t.textMuted)
                    .rotationEffect(.degrees(-90)).fixedSize().frame(width: 14)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(other.loaded ? other.title : (suggestion?.track.title ?? "Choose the next track"))
                            .font(t.ui(15, .semibold)).oneLine()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let a = (other.loaded ? session.track(other.trackID) : suggestion?.track)?.analysis {
                            Text("\(Format.bpm(a.bpm)) · \(a.camelot)").font(t.mono(12)).readout()
                        }
                    }
                    if let m = suggestion?.match, !other.loaded, m.score > 0 {
                        HStack(spacing: 10) {
                            if m.harmony == .same || m.harmony == .compatible {
                                Label("HARMONIC", systemImage: "checkmark").foregroundStyle(t.success)
                            }
                            Text(String(format: "%+.1f%% TEMPO", m.tempoChangePercent)).foregroundStyle(t.textMuted)
                        }
                        .labelStyle(CompactLabel())
                        .font(t.mono(10, .medium)).tracking(0.6)
                    }
                }
            }
            .foregroundStyle(t.text)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(t.border).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, t.pad)
    }

    private func footer(_ i: Int) -> some View {
        HStack(spacing: 12) {
            Button { actions.openLibrary() } label: { Image(systemName: "list.bullet").frame(width: 20) }
                .buttonStyle(ObsidianButtonStyle())
                .accessibilityLabel("Library")
            Button { session.togglePlay(i) } label: {
                Image(systemName: session.decks[i].playing ? "pause.fill" : "play.fill").frame(width: 20)
            }
            .buttonStyle(ObsidianButtonStyle())
            .accessibilityLabel(session.decks[i].playing ? "Pause" : "Play")
            Button { actions.openDeckTools(i) } label: { Image(systemName: "record.circle").frame(width: 20) }
                .buttonStyle(ObsidianButtonStyle())
                .accessibilityLabel("Deck tools: jog, loops, cues, EQ and FX")
            Button { actions.openVisualizer() } label: { Image(systemName: "waveform.path.ecg.rectangle").frame(width: 20) }
                .buttonStyle(ObsidianButtonStyle())
                .accessibilityLabel("Visualizer")
            LevelMeter(left: session.masterPeak, right: session.masterPeak)
        }
        .padding(.horizontal, t.pad)
    }
}
