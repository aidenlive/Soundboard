import SwiftUI
import SoundboardAudio

/// Persists Appearance in UserDefaults (synced preferences come later via the sync service).
@MainActor
@Observable
public final class AppearanceStore {
    public var appearance: Appearance { didSet { save() } }
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "soundboard.appearance.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let a = try? JSONDecoder().decode(Appearance.self, from: data) {
            appearance = a
        } else {
            appearance = Appearance()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(appearance) { defaults.set(data, forKey: Self.key) }
    }
}

/// Actions the screens ask the root to perform (sheets, file import).
struct AppActions {
    var openLibrary: () -> Void
    var openSettings: () -> Void
    var importMusic: () -> Void
    var openSessions: () -> Void = {}
    var openDeckTools: (Int) -> Void = { _ in }
    var openVisualizer: () -> Void = {}
}

/// The space the app has, so screens adapt without measuring themselves.
/// Thresholds: an iPhone SE is 375 × 667 pt; iPhone landscape heights are 375–440 pt.
struct LayoutMetrics: Equatable {
    var size: CGSize = CGSize(width: 390, height: 844)
    /// Portrait phone shorter than an iPhone 12/13/14 (≈ 844 pt): trim to essentials.
    var shortPortrait: Bool { size.height < 760 }
    /// Landscape phone: little height for the deck area.
    var shortLandscape: Bool { size.height < 480 }
    var narrow: Bool { size.width < 380 }
}

private struct LayoutMetricsKey: EnvironmentKey { static let defaultValue = LayoutMetrics() }

extension EnvironmentValues {
    var layout: LayoutMetrics {
        get { self[LayoutMetricsKey.self] }
        set { self[LayoutMetricsKey.self] = newValue }
    }
}

/// Typography rules every screen follows, so values never shift a layout:
/// - readouts (BPM, time, %, dB) use tabular figures, one line, and keep their width;
/// - titles are one line and truncate at the end;
/// - labels in fixed-size controls shrink slightly before they would clip.
extension View {
    func readout() -> some View { monospacedDigit().lineLimit(1).fixedSize() }
    func oneLine() -> some View { lineLimit(1).truncationMode(.tail) }
    func fittedLabel() -> some View { lineLimit(1).minimumScaleFactor(0.75) }
}

private struct AppActionsKey: EnvironmentKey {
    static let defaultValue = AppActions(openLibrary: {}, openSettings: {}, importMusic: {})
}

extension EnvironmentValues {
    var appActions: AppActions {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}

enum Format {
    static func time(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
    /// Track length, m:ss (h:mm:ss past an hour). Empty when unknown.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    static func bpm(_ v: Double) -> String { v > 0 ? String(format: "%.2f", v) : "—" }
    static func tempo(_ ratio: Double) -> String { String(format: "%+.2f%%", (ratio - 1) * 100) }
}

/// Which deck the beginner view is "about": the playing one, else the first loaded.
extension DJSession {
    var focusDeck: Int { decks.firstIndex(where: { $0.playing }) ?? decks.firstIndex(where: { $0.loaded }) ?? 0 }
}

/// Route status in plain words: where the music goes, and whether private cueing works.
@MainActor
struct RouteChip: View {
    let session: DJSession
    @Environment(\.obsidian) private var t
    var body: some View {
        HStack(spacing: 14) {
            Label(session.plan?.masterPort?.name.uppercased() ?? "NO OUTPUT", systemImage: "speaker.wave.2")
            Label(session.cueAvailable ? "CUE · \(session.plan?.cuePort?.name.uppercased() ?? "")" : "CUE —", systemImage: "headphones")
                .foregroundStyle(session.cueAvailable ? t.text : t.textMuted)
        }
        .labelStyle(CompactLabel())
        .font(t.mono(10, .medium))
        .tracking(1)
        .foregroundStyle(t.textMuted)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .combine)
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The deck in whichever view the user chose in Appearance.
@MainActor
struct DeckDisplay: View {
    let deck: DeckState
    var secondsVisible: Double = 8
    var compactCenter = false
    @Environment(\.obsidian) private var t

    var body: some View {
        switch t.appearance.deckView {
        case .linear:
            ScrollingWaveform(deck.visual, deck: deck.deck, secondsVisible: secondsVisible)
        case .lanes:
            ScrollingWaveform(deck.visual, deck: deck.deck, secondsVisible: secondsVisible, axis: .vertical)
        case .radial:
            RadialDeck(deck.visual, deck: deck.deck) {
                VStack(spacing: 2) {
                    if !compactCenter {
                        Text("\(deck.camelot.isEmpty ? "—" : deck.camelot) · BAR \(PhraseClock.bar(atBeat: deck.beat))")
                            .font(t.mono(10, .medium)).tracking(1).foregroundStyle(t.textMuted)
                    }
                    Text(Format.bpm(deck.effectiveBpm)).font(t.mono(compactCenter ? 22 : 38, .medium)).tracking(-1).readout()
                    Text("−" + Format.time(deck.remaining)).font(t.mono(11)).foregroundStyle(t.textSecondary).readout()
                }
                .foregroundStyle(t.text)
            }
        }
    }
}

/// Transition picker + the Mix button, with the phrase countdown.
@MainActor
struct MixControls: View {
    @Bindable var session: DJSession
    var showPicker = true
    @Environment(\.obsidian) private var t

    var body: some View {
        VStack(spacing: 10) {
            if showPicker {
                Segmented(TransitionKind.allCases.map { ($0, $0.title) }, selection: $session.transition)
            }
            Button {
                if session.transitionProgress >= 0 || session.transitionStartsInBeats >= 0 {
                    session.cancelTransition()
                } else {
                    Task { await session.mix() }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(title).font(t.ui(17, .semibold)).oneLine()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(detail).font(t.mono(11, .medium)).tracking(0.8).readout()
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 58)
                .foregroundStyle(t.onPrimary)
                .background(t.primary)
                .clipShape(RoundedRectangle(cornerRadius: t.radius))
            }
            .buttonStyle(.plain)
            .disabled(!session.decks.contains(where: { $0.loaded }))
            .accessibilityHint("Blends into the next track on the next phrase")
        }
    }

    private var other: DeckState { session.decks[1 - session.focusDeck] }

    private var title: String {
        if session.transitionStartsInBeats >= 0 { return "Mixing on the phrase…" }
        if session.transitionProgress >= 0 { return "Mixing" }
        if !session.decks[session.focusDeck].playing { return "Play" }
        let name = other.loaded ? other.title : (session.upNext.first?.track.title ?? "next track")
        return "Mix into \(name)"
    }

    private var detail: String {
        if session.transitionStartsInBeats >= 0 { return "IN \(Int(ceil(Double(session.transitionStartsInBeats)))) · TAP TO CANCEL" }
        if session.transitionProgress >= 0 { return "\(Int(session.transitionProgress * 100))% · TAP TO CANCEL" }
        let beats = PhraseClock.beatsToNextPhrase(atBeat: session.decks[session.focusDeck].beat)
        return "\(session.transitionBeats) BEATS · PHRASE IN \(beats)"
    }
}

/// Five knobs for a deck: trim, high, mid, low, filter.
@MainActor
struct KnobRow: View {
    let session: DJSession
    let deck: Int
    var size: CGFloat = 52
    @Environment(\.obsidian) private var t

    var body: some View {
        let d = session.decks[deck]
        HStack(alignment: .top) {
            Knob("Trim", value: binding(.trim, d.trim), valueText: String(format: "%+.1f dB", d.trim * 12), size: size)
            Spacer(minLength: 4)
            Knob("High", value: binding(.high, d.high), valueText: DJSession.eqText(d.high), size: size)
            Spacer(minLength: 4)
            Knob("Mid", value: binding(.mid, d.mid), valueText: DJSession.eqText(d.mid), size: size)
            Spacer(minLength: 4)
            Knob("Low", value: binding(.low, d.low), valueText: DJSession.eqText(d.low), size: size)
            Spacer(minLength: 4)
            Knob("Filter", value: binding(.filter, d.filter),
                 valueText: abs(d.filter) < 0.02 ? "off" : (d.filter < 0 ? "low-pass \(Int(-d.filter * 100))%" : "high-pass \(Int(d.filter * 100))%"),
                 tint: Color(t.palette.wave(.a).low), size: size)
        }
    }

    private func binding(_ c: DJSession.Control, _ v: Double) -> Binding<Double> {
        Binding(get: { v }, set: { session.set(c, deck: deck, $0) })
    }
}

/// Shown before any music is loaded.
@MainActor
struct EmptyDeckView: View {
    let session: DJSession
    @Environment(\.obsidian) private var t
    @Environment(\.appActions) private var actions

    var body: some View {
        // One brand element at a time, in the same box: Pulse while analysing, the mark otherwise.
        let busy = session.library.busyCount
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Group {
                if busy > 0 { Pulse(bars: 9) } else { SplitMark() }
            }
            .frame(width: 88, height: 88)
            Group {
                if busy > 0 {
                    Text("Analysing \(busy) track\(busy == 1 ? "" : "s")").font(t.ui(17, .semibold))
                    Text("Tempo, key and loudness. You can start as soon as one is ready.")
                        .font(t.ui(14)).foregroundStyle(t.textSecondary)
                } else if session.library.tracks.isEmpty {
                    Text("Add music to start mixing").font(t.ui(17, .semibold))
                    Text("Pick songs from Files. Soundboard finds the tempo, key and loudness of each one.")
                        .font(t.ui(14)).foregroundStyle(t.textSecondary)
                    Button("ADD MUSIC") { actions.importMusic() }.buttonStyle(ObsidianButtonStyle(prominent: true))
                } else {
                    Text("Pick a track to play").font(t.ui(17, .semibold))
                    Button("OPEN LIBRARY") { actions.openLibrary() }.buttonStyle(ObsidianButtonStyle(prominent: true))
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300)
            Spacer(minLength: 0)
        }
        .foregroundStyle(t.text)
        .padding(.horizontal, t.pad)
        .frame(maxWidth: .infinity)
    }
}

/// The open session's name; tap to switch, rename or start another.
@MainActor
struct SessionChip: View {
    let session: DJSession
    @Environment(\.obsidian) private var t
    @Environment(\.appActions) private var actions

    var body: some View {
        Button { actions.openSessions() } label: {
            HStack(spacing: 4) {
                Text(session.sessions.current?.name ?? "Session").lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .font(t.mono(10, .medium)).tracking(1)
            .foregroundStyle(t.textSecondary)
            .frame(maxWidth: 160, alignment: .leading)
            .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Session \(session.sessions.current?.name ?? "")")
        .accessibilityHint("Switch, rename or start a session")
    }
}

/// Per-deck actions that are not worth a permanent button.
@MainActor
struct DeckMenu: View {
    let session: DJSession
    let index: Int
    @Environment(\.obsidian) private var t
    @Environment(\.appActions) private var actions

    var body: some View {
        let d = session.decks[index]
        Menu {
            Button { actions.openLibrary() } label: { Label(d.loaded ? "Load another track" : "Load a track", systemImage: "music.note.list") }
            Button { actions.openDeckTools(index) } label: { Label("Deck tools: jog, loops, cues, FX", systemImage: "record.circle") }
            if d.loaded {
                Button { let id = d.trackID!; session.eject(index); session.enqueue([id]) } label: { Label("Eject to queue", systemImage: "text.badge.plus") }
                Button(role: .destructive) { session.eject(index) } label: { Label("Eject deck \(d.letter)", systemImage: "eject") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .foregroundStyle(t.textSecondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Deck \(d.letter) options")
    }
}

/// Mixer-wide actions.
@MainActor
struct MixerMenu: View {
    let session: DJSession
    @Environment(\.obsidian) private var t
    @State private var confirmReset = false

    var body: some View {
        Menu {
            Button { confirmReset = true } label: { Label("Reset mixer", systemImage: "arrow.counterclockwise") }
                .disabled(session.mixerIsNeutral)
        } label: {
            Image(systemName: "dial.low").frame(width: 44, height: 32).foregroundStyle(t.textSecondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Mixer options")
        .confirmationDialog("Reset the mixer?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset mixer", role: .destructive) { session.resetMixer() }
        } message: {
            Text("EQ, trim and filter go to centre and channel faders to full. The crossfader moves to the deck that is playing. Tracks keep playing.")
        }
    }
}
