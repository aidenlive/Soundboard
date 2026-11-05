import SwiftUI
import SoundboardAudio

/// Settings › Appearance. Every choice only changes token values or which deck view is drawn.
@MainActor
struct AppearanceView: View {
    @Bindable var store: AppearanceStore
    let session: DJSession
    @Environment(\.obsidian) private var t

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview
                section("Theme") {
                    HStack(spacing: 8) {
                        ForEach(Appearance.Theme.allCases) { th in themeTile(th) }
                    }
                }
                section("Accent") {
                    HStack(spacing: 12) {
                        ForEach(Appearance.Accent.allCases) { a in accentSwatch(a) }
                        Text(store.appearance.accent.title).font(t.ui(13)).foregroundStyle(t.textSecondary)
                    }
                }
                section("Deck view") {
                    Segmented(Appearance.DeckView.allCases.map { ($0, $0.title) }, selection: $store.appearance.deckView, mono: false)
                }
                NavigationLink {
                    WaveformColorsView(store: store)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Eyebrow("Waveform colours")
                            Text(store.appearance.waveform.title).font(t.ui(14)).foregroundStyle(t.text)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(t.textMuted)
                    }
                    .padding(12)
                    .background(t.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                section("Density") {
                    Segmented(Appearance.Density.allCases.map { ($0, $0.title) }, selection: $store.appearance.density, mono: false)
                }
                VStack(spacing: 1) {
                    Toggle("Follow system light / dark", isOn: $store.appearance.followSystem)
                        .padding(12).background(t.surface)
                    Toggle("Per-controller layouts", isOn: $store.appearance.perControllerLayouts)
                        .padding(12).background(t.surface)
                }
                .font(t.ui(14))
                .foregroundStyle(t.text)
                .tint(t.primary)
                .background(t.border)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(t.pad)
        }
        .background(t.background)
        .navigationTitle("Appearance")
    }

    @ViewBuilder private var preview: some View {
        let deck = session.decks.first(where: { $0.loaded }) ?? DemoDeck.state
        DeckDisplay(deck: deck, secondsVisible: 6)
            .frame(height: 170)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(t.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.border, lineWidth: 1))
            .overlay(alignment: .bottomLeading) {
                Text("MIX").font(t.mono(10, .medium)).tracking(1).foregroundStyle(t.onPrimary)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(t.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 3)).padding(10)
            }
            .accessibilityLabel("Preview")
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title)
            content()
        }
    }

    private func themeTile(_ th: Appearance.Theme) -> some View {
        let p = SemanticPalette.make({ var a = store.appearance; a.theme = th; a.followSystem = false; return a }())
        let on = store.appearance.theme == th
        return Button { store.appearance.theme = th } label: {
            VStack(alignment: .leading) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach([10, 18, 12], id: \.self) { h in Rectangle().fill(Color(p.text)).frame(width: 3, height: CGFloat(h)) }
                }
                Spacer()
                Text(th.title).font(t.ui(12, .medium)).foregroundStyle(Color(p.text))
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color(p.background))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? t.primary : t.border, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(th.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func accentSwatch(_ a: Appearance.Accent) -> some View {
        let family = ObsidianTokens.accents[a.rawValue]?["family"] ?? "lime"
        let c = ObsidianTokens.palette["\(family).500"] ?? OKLCH(0.88, 0.21, 128)
        let on = store.appearance.accent == a
        return Button { store.appearance.accent = a } label: {
            Circle().fill(Color(c)).padding(3)
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(on ? t.text : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(a.title) accent")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Settings › Appearance › Waveform colours, including the guarded Custom editor.
@MainActor
struct WaveformColorsView: View {
    @Bindable var store: AppearanceStore
    @Environment(\.obsidian) private var t

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Colours show frequency: what's low, mid and high in the music. Your accent stays for buttons and active states.")
                    .font(t.ui(13)).foregroundStyle(t.textSecondary).padding(.bottom, 6)
                ForEach(Appearance.Waveform.allCases) { w in row(w) }
                if store.appearance.waveform == .custom { customEditor }
                HStack(spacing: 8) {
                    Rectangle().fill(t.text).frame(width: 2, height: 14)
                    Text("The playhead, beat grid, phrase markers and cue ticks stay fixed in every preset.")
                }
                .font(t.ui(12)).foregroundStyle(t.textMuted).padding(.top, 8)
            }
            .padding(t.pad)
        }
        .background(t.background)
        .navigationTitle("Waveform colours")
    }

    private func row(_ w: Appearance.Waveform) -> some View {
        var a = store.appearance
        a.waveform = w
        let theme = ObsidianTheme(appearance: a)
        let on = store.appearance.waveform == w
        return Button { store.appearance.waveform = w } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(w.title).font(t.ui(14, .semibold))
                    if w == .spectral { Text("DEFAULT").font(t.mono(9, .medium)).tracking(1).foregroundStyle(t.textMuted) }
                    Spacer()
                    Text(w.subtitle).font(t.ui(12)).foregroundStyle(t.textMuted).lineLimit(1)
                }
                .foregroundStyle(t.text)
                HStack(spacing: 4) {
                    ScrollingWaveform(DemoDeck.state.visual, deck: .a, secondsVisible: 10)
                    ScrollingWaveform(DemoDeck.stateB.visual, deck: .b, secondsVisible: 10)
                }
                .frame(height: 26)
                .environment(\.obsidian, theme)
            }
            .padding(10)
            .background(t.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? t.primary : t.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(w.title). \(w.subtitle)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var customEditor: some View {
        let resolved = store.appearance.customWaveform.resolve()
        return VStack(alignment: .leading, spacing: 10) {
            band("LOW", \.low, step: "600", allowWhite: false)
            band("MID", \.mid, step: "400", allowWhite: false)
            band("HIGH", \.high, step: "200", allowWhite: true)
            if !resolved.notes.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(t.warning).frame(width: 6, height: 6).padding(.top, 5)
                    Text(resolved.notes.joined(separator: " ")).font(t.ui(12)).foregroundStyle(t.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
    }

    private func band(_ label: String, _ path: WritableKeyPath<CustomWaveform, CustomWaveform.Hue>, step: String, allowWhite: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label).font(t.mono(10, .medium)).tracking(1).foregroundStyle(t.textMuted).frame(width: 40, alignment: .leading)
            ForEach(CustomWaveform.Hue.allCases.filter { allowWhite || $0 != .white }) { hue in
                let key = hue == .white ? "neutral.0" : "\(hue.rawValue).\(step)"
                let on = store.appearance.customWaveform[keyPath: path] == hue
                Button { store.appearance.customWaveform[keyPath: path] = hue } label: {
                    Circle().fill(Color(ObsidianTokens.palette[key] ?? OKLCH(1, 0, 0))).padding(2)
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(on ? t.text : Color.clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("\(label.capitalized) band: \(hue.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Synthetic deck for previews when nothing is loaded.
enum DemoDeck {
    static let state: DeckState = make(seed: 1.3)
    static let stateB: DeckState = make(seed: 4.7, index: 1)

    static func make(seed: Double, index: Int = 0) -> DeckState {
        var d = DeckState(index: index)
        let n = 4000
        func r(_ i: Int, _ s: Double) -> Float {
            let x = sin(Double(i) * 12.9898 + s * 78.233) * 43758.5453
            return Float(x - floor(x))
        }
        var low = [Float](), mid = [Float](), high = [Float]()
        for i in 0..<n {
            let kick: Float = (i / 37) % 4 == 0 && i % 37 < 8 ? 1 : 0.45
            low.append(min(1, kick * (0.75 + 0.25 * r(i, seed))))
            mid.append(0.3 + 0.4 * r(i, seed + 1))
            high.append(0.15 + 0.4 * r(i, seed + 2))
        }
        d.visual.waveform = WaveformData(low: low, mid: mid, high: high, framesPerBin: 294, sampleRate: 44_100)
        d.visual.bpm = 120
        d.visual.position = Double(n * 294) * 0.42
        d.visual.cues = [(index: 0, frame: Double(n * 294) * 0.2), (index: 1, frame: Double(n * 294) * 0.5)]
        d.trackID = UUID()
        d.title = "Preview"
        d.effectiveBpm = 120
        d.camelot = "8A"
        d.frames = Double(n * 294)
        return d
    }
}
