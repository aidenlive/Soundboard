import SwiftUI
import UniformTypeIdentifiers
import SoundboardAudio
#if os(macOS)
import AppKit
#endif

/// The app's root: picks Quick or Mix for the space available, applies the Appearance theme,
/// runs the launch sequence, and hosts the library, settings, sessions, deck tools, visualizer
/// and file import.
@MainActor
public struct SoundboardRootView: View {
    @State private var session = DJSession()
    @State private var store = AppearanceStore()
    @State private var sheet: Sheet?
    @State private var importing = false
    @State private var launching = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    enum Sheet: Identifiable, Hashable {
        case library, settings, sessions, visualizer, deckTools(Int)
        var id: String {
            switch self {
            case .library: "library"
            case .settings: "settings"
            case .sessions: "sessions"
            case .visualizer: "visualizer"
            case .deckTools(let i): "deck-\(i)"
            }
        }
    }

    public init() {
        ObsidianFonts.register()
    }

    public var body: some View {
        let theme = ObsidianTheme(appearance: store.appearance, systemIsDark: scheme == .dark)
        let actions = AppActions(openLibrary: { sheet = .library },
                                 openSettings: { sheet = .settings },
                                 importMusic: { importing = true },
                                 openSessions: { sheet = .sessions },
                                 openDeckTools: { sheet = .deckTools($0) },
                                 openVisualizer: { sheet = .visualizer })
        GeometryReader { geo in
            // Mix needs width more than orientation: iPad portrait (≥ 700 pt) gets Mix too.
            let mix = geo.size.width > geo.size.height || geo.size.width >= 700
            let roomy = geo.size.width >= 1000 && geo.size.height >= 600
            Group {
                if mix {
                    MixView(session: session, roomy: roomy)
                } else {
                    QuickView(session: session)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .environment(\.layout, LayoutMetrics(size: geo.size))
        }
        .overlay {
            if launching {
                LaunchView(isReady: { [session] in session.phase == .ready }) {
                    withAnimation(.easeOut(duration: 0.3)) { launching = false }
                }
                .transition(.opacity)
            }
        }
        .background(theme.background.ignoresSafeArea())
        .environment(\.obsidian, theme)
        .environment(\.appActions, actions)
        .preferredColorScheme(store.appearance.followSystem ? nil : (theme.isDark ? .dark : .light))
        .tint(theme.primary)
        .sheet(item: $sheet) { which in
            NavigationStack {
                switch which {
                case .library: LibraryView(session: session)
                case .settings: SettingsView(store: store, session: session)
                case .sessions: SessionsSheet(session: session)
                case .visualizer: VisualizerPanel(session: session)
                case .deckTools(let i): DeckToolsPanel(session: session, index: i)
                }
            }
            .environment(\.obsidian, ObsidianTheme(appearance: store.appearance, systemIsDark: scheme == .dark))
            .environment(\.appActions, AppActions(openLibrary: {}, openSettings: {}, importMusic: { importing = true }))
            .presentationBackground(theme.background)
            .presentationDetents(detents(for: which))
            .tint(theme.primary)
            #if os(macOS)
            .frame(minWidth: macWidth(for: which), minHeight: 600)
            #endif
            // The picker must hang off the sheet while one is open, else iOS won't present it.
            .fileImporter(isPresented: $importing, allowedContentTypes: AudioFormats.importTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { session.importFiles(urls) }
            }
        }
        .fileImporter(isPresented: Binding(get: { importing && sheet == nil }, set: { importing = $0 }),
                      allowedContentTypes: AudioFormats.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { session.importFiles(urls) }
        }
        .onChange(of: session.preferences.prefs) { old, _ in session.preferencesChanged(from: old) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.saveNow(); session.library.saveNow() }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            session.saveNow()
            session.library.saveNow()
        }
        #endif
        .task {
            VisualizerHub.shared.attach(session)
            await session.start()
        }
    }

    private func detents(for sheet: Sheet) -> Set<PresentationDetent> {
        if case .deckTools = sheet { return [.medium, .large] }
        return [.large]
    }

    #if os(macOS)
    private func macWidth(for sheet: Sheet) -> CGFloat {
        switch sheet {
        case .library: 680
        case .visualizer, .deckTools: 640
        default: 560
        }
    }
    #endif
}
