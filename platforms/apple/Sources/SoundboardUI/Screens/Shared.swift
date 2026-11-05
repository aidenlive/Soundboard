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
                    Text(Format.bpm(deck.effectiveBpm)).font(t.mono(compactCenter ? 22 : 38, .medium)).tracking(-1)
                    Text("−" + Format.time(deck.remaining)).font(t.mono(11)).foregroundStyle(t.textSecondary)
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
                HStack {
                    Text(title).font(t.ui(17, .semibold))
                    Spacer()
                    Text(detail).font(t.mono(11, .medium)).tracking(0.8)
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
        VStack(spacing: 20) {
            Spacer()
            SplitMark().frame(width: 96, height: 96)
            if session.analysingCount > 0 {
                HStack(spacing: 10) {
                    Pulse().frame(width: 36, height: 36)
                    Text("Analysing \(session.analysingCount) track\(session.analysingCount == 1 ? "" : "s")").font(t.ui(15, .medium))
                }
            } else if session.library.isEmpty {
                Text("Add music to start mixing").font(t.ui(17, .semibold))
                Text("Pick songs from Files. Soundboard finds the tempo, key and loudness of each one.")
                    .font(t.ui(14)).foregroundStyle(t.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 300)
                Button("ADD MUSIC") { actions.importMusic() }.buttonStyle(ObsidianButtonStyle(prominent: true))
            } else {
                Text("Pick a track to play").font(t.ui(17, .semibold))
                Button("OPEN LIBRARY") { actions.openLibrary() }.buttonStyle(ObsidianButtonStyle(prominent: true))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
