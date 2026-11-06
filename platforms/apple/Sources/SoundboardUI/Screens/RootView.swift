import SwiftUI
import UniformTypeIdentifiers
import SoundboardAudio
#if os(macOS)
import AppKit
#endif

/// The app's root: picks Quick (portrait phone) or Mix (landscape, iPad, Mac), applies the
/// Appearance theme, and hosts the library, settings, sessions and file import.
@MainActor
public struct SoundboardRootView: View {
    @State private var session = DJSession()
    @State private var store = AppearanceStore()
    @State private var sheet: Sheet?
    @State private var importing = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    enum Sheet: String, Identifiable { case library, settings, sessions; var id: String { rawValue } }

    public init() {
        ObsidianFonts.register()
    }

    public var body: some View {
        let theme = ObsidianTheme(appearance: store.appearance, systemIsDark: scheme == .dark)
        let actions = AppActions(openLibrary: { sheet = .library },
                                 openSettings: { sheet = .settings },
                                 importMusic: { importing = true },
                                 openSessions: { sheet = .sessions })
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
        .environment(\.appActions, actions)
        .preferredColorScheme(store.appearance.followSystem ? nil : (theme.isDark ? .dark : .light))
        .tint(theme.primary)
        .sheet(item: $sheet) { which in
            NavigationStack {
                switch which {
                case .library: LibraryView(session: session)
                case .settings: SettingsView(store: store, session: session)
                case .sessions: SessionsSheet(session: session)
                }
            }
            .environment(\.obsidian, ObsidianTheme(appearance: store.appearance, systemIsDark: scheme == .dark))
            .environment(\.appActions, AppActions(openLibrary: {}, openSettings: {}, importMusic: { importing = true }))
            .presentationBackground(theme.background)
            .tint(theme.primary)
            #if os(macOS)
            .frame(minWidth: which == .library ? 680 : 560, minHeight: 600)
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
        .task { await session.start() }
    }
}
