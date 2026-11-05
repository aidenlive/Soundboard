import SwiftUI
import UniformTypeIdentifiers
import SoundboardAudio

/// The app's root: picks Quick (portrait phone) or Mix (landscape, iPad, Mac), applies the
/// Appearance theme, and hosts the library, settings and file import.
@MainActor
public struct SoundboardRootView: View {
    @State private var session = DJSession()
    @State private var store = AppearanceStore()
    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var importing = false
    @Environment(\.colorScheme) private var scheme

    public init() {
        ObsidianFonts.register()
    }

    public var body: some View {
        let theme = ObsidianTheme(appearance: store.appearance, systemIsDark: scheme == .dark)
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let roomy = geo.size.width >= 1000 && geo.size.height >= 600
            Group {
                if landscape {
                    MixView(session: session, roomy: roomy)
                } else {
                    QuickView(session: session)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(theme.background.ignoresSafeArea())
        .environment(\.obsidian, theme)
        .environment(\.appActions, AppActions(openLibrary: { showLibrary = true },
                                              openSettings: { showSettings = true },
                                              importMusic: { importing = true }))
        .preferredColorScheme(store.appearance.followSystem ? nil : (theme.isDark ? .dark : .light))
        .tint(theme.primary)
        .sheet(isPresented: $showLibrary) {
            NavigationStack { LibraryView(session: session) }
                .environment(\.obsidian, theme)
                .environment(\.appActions, AppActions(openLibrary: {}, openSettings: {}, importMusic: { importing = true }))
                .presentationBackground(theme.background)
                #if os(macOS)
                .frame(minWidth: 640, minHeight: 560)
                #endif
                .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { session.importFiles(urls) }
                }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(store: store, session: session)
            }
            .environment(\.obsidian, ObsidianTheme(appearance: store.appearance, systemIsDark: scheme == .dark))
            .presentationBackground(theme.background)
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 640)
            #endif
        }
        .fileImporter(isPresented: Binding(get: { importing && !showLibrary }, set: { importing = $0 }),
                      allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { session.importFiles(urls) }
        }
        .task { session.start() }
    }
}

/// Settings: Appearance plus audio routing.
@MainActor
struct SettingsView: View {
    @Bindable var store: AppearanceStore
    @Bindable var session: DJSession
    @Environment(\.obsidian) private var t
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink { AppearanceView(store: store, session: session) } label: { navRow("Appearance", store.appearance.theme.title + " · " + store.appearance.accent.title) }
                    .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Audio")
                    infoRow("Master", session.plan?.masterPort?.name ?? "—")
                    infoRow("Headphones", session.cueAvailable ? (session.plan?.cuePort?.name ?? "—") : "Not available")
                    Toggle("I'm using a splitter cable", isOn: $session.splitterCable)
                        .font(t.ui(14)).foregroundStyle(t.text).tint(t.primary)
                    ForEach(Array(notices.enumerated()), id: \.offset) { _, n in
                        Label(n, systemImage: "exclamationmark.triangle").font(t.ui(13)).foregroundStyle(t.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Headphone mix")
                        Fader("Cue and master blend", value: $session.cueMix, in: 0...1, leading: "CUE", trailing: "MASTER")
                        Fader("Headphone volume", value: $session.headphoneVolume, in: 0...1, leading: "VOL")
                    }
                    .disabled(!session.cueAvailable)
                }
                .padding(12)
                .background(t.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
                if let e = session.errorMessage {
                    Text(e).font(t.ui(13)).foregroundStyle(t.error)
                }
            }
            .padding(t.pad)
        }
        .background(t.background)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private var notices: [String] {
        (session.plan?.notices ?? []).map {
            switch $0 {
            case .cueNeedsHardware: "Private pre-listening needs a splitter cable, a USB audio interface or a DJ controller."
            case .wirelessMasterLatency(let ms): "Wireless speakers add about \(ms) ms; the waveform is shifted to match."
            case .wirelessCueLatency(let ms): "Wireless headphones add about \(ms) ms. Wired headphones are recommended for cueing."
            case .airPlayNotForLiveMixing: "AirPlay buffers for about two seconds: fine for playback, not for live mixing."
            case .cueSlowerThanMaster(let ms): "Your headphones are \(ms) ms behind the speakers."
            }
        }
    }

    private func navRow(_ title: String, _ value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(title)
                Text(value).font(t.ui(14)).foregroundStyle(t.text)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(t.textMuted)
        }
        .padding(12)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(t.ui(14)).foregroundStyle(t.textSecondary)
            Spacer()
            Text(v).font(t.ui(14)).foregroundStyle(t.text).lineLimit(1)
        }
    }
}
