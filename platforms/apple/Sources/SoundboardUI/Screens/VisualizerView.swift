import SwiftUI
import SoundboardAudio
#if os(iOS)
import UIKit
#endif

/// Draws one `VisualFrame` in the chosen style. Pure drawing: no state, no controls.
@MainActor
struct VisualizerCanvas: View {
    let frame: VisualFrame
    let prefs: VisualizerPrefs
    @Environment(\.obsidian) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = palette()
        // On the beat: a short swell that decays over the first fifth of the beat.
        let kick = prefs.beatReactive && frame.playing && !reduceMotion ? max(0, 1 - frame.beatPhase * 5) : 0
        Canvas { ctx, size in
            switch prefs.style {
            case .spectrum: spectrum(ctx, size, colors, kick)
            case .radial: radial(ctx, size, colors, kick)
            case .scope: scope(ctx, size, colors, kick)
            case .pulse: pulse(ctx, size, colors, kick)
            }
        }
        .background(Color.black)
        .accessibilityHidden(true)
    }

    /// Three colours: low, mid, high. Spectral uses the waveform bands so the screen matches the decks.
    private func palette() -> [Color] {
        switch prefs.palette {
        case .spectral:
            let w = t.palette.wave(.a)
            return [Color(w.low), Color(w.mid), Color(w.high)]
        case .accent: return [t.primary, t.primary.opacity(0.75), Color.white]
        case .mono: return [Color.white, Color.white.opacity(0.7), Color.white.opacity(0.45)]
        }
    }

    private func color(_ colors: [Color], band: Int) -> Color {
        colors[min(2, band * 3 / 32)]
    }

    private func spectrum(_ ctx: GraphicsContext, _ size: CGSize, _ colors: [Color], _ kick: Double) {
        let n = frame.bands.count
        let gap: CGFloat = max(2, size.width * 0.004)
        let w = (size.width - gap * CGFloat(n + 1)) / CGFloat(n)
        let base = size.height * 0.5
        for (i, v) in frame.bands.enumerated() {
            let h = max(2, CGFloat(v) * size.height * 0.42 * (1 + CGFloat(kick) * 0.12))
            let x = gap + CGFloat(i) * (w + gap)
            let up = CGRect(x: x, y: base - h, width: w, height: h)
            let down = CGRect(x: x, y: base, width: w, height: h * 0.45)
            ctx.fill(Path(roundedRect: up, cornerRadius: min(w / 2, 4)), with: .color(color(colors, band: i)))
            ctx.fill(Path(roundedRect: down, cornerRadius: min(w / 2, 4)), with: .color(color(colors, band: i).opacity(0.25)))
        }
    }

    private func radial(_ ctx: GraphicsContext, _ size: CGSize, _ colors: [Color], _ kick: Double) {
        guard !frame.bands.isEmpty else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r0 = min(size.width, size.height) * (0.22 + 0.03 * CGFloat(kick))
        let maxLen = min(size.width, size.height) * 0.24
        let n = frame.bands.count * 2
        for i in 0..<n {
            // Mirror the bands so lows sit at the top and bottom.
            let b = i < n / 2 ? i : n - 1 - i
            let v = CGFloat(frame.bands[b])
            let a = Double(i) / Double(n) * 2 * .pi - .pi / 2
            let len = max(3, v * maxLen)
            var p = Path()
            p.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
            p.addLine(to: CGPoint(x: c.x + cos(a) * (r0 + len), y: c.y + sin(a) * (r0 + len)))
            ctx.stroke(p, with: .color(color(colors, band: b)), style: StrokeStyle(lineWidth: max(2, r0 * 0.05), lineCap: .round))
        }
        let ring = r0 * 0.82
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)),
                   with: .color(colors[0].opacity(0.3 + 0.5 * kick)), lineWidth: 2)
    }

    private func scope(_ ctx: GraphicsContext, _ size: CGSize, _ colors: [Color], _ kick: Double) {
        guard frame.scope.count > 1 else { return }
        let mid = size.height / 2
        let amp = size.height * 0.4
        var p = Path()
        for (i, s) in frame.scope.enumerated() {
            let x = CGFloat(i) / CGFloat(frame.scope.count - 1) * size.width
            let y = mid - CGFloat(max(-1, min(1, s * 2.5))) * amp
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(p, with: .color(colors[1].opacity(0.25)), style: StrokeStyle(lineWidth: 10 + 8 * kick, lineJoin: .round))
        ctx.stroke(p, with: .color(colors[1]), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }

    /// The brand's Pulse: bars on an S-curve, the centre bar in the accent, driven by the music.
    private func pulse(_ ctx: GraphicsContext, _ size: CGSize, _ colors: [Color], _ kick: Double) {
        guard !frame.bands.isEmpty else { return }
        let n = 15
        let s = min(size.width, size.height * 1.4) / 100
        let ox = (size.width - 100 * s) / 2, oy = (size.height - 100 * s) / 2
        let w: CGFloat = 4.4, gap: CGFloat = 2
        let total = CGFloat(n) * w + CGFloat(n - 1) * gap
        let x0 = 50 - total / 2
        for i in 0..<n {
            let tt = CGFloat(i) / CGFloat(n - 1)
            let band = min(frame.bands.count - 1, Int(tt * CGFloat(frame.bands.count - 1)))
            let v = CGFloat(frame.bands[band])
            let cy = 50 - 15 * sin(tt * 2 * .pi)
            let midBar = i == n / 2
            let h = midBar ? 30 + 40 * CGFloat(frame.level) + 8 * CGFloat(kick) : 8 + 46 * v
            let rect = CGRect(x: ox + (x0 + CGFloat(i) * (w + gap)) * s, y: oy + (cy - h / 2) * s, width: w * s, height: h * s)
            ctx.fill(Path(roundedRect: rect, cornerRadius: w * s / 2), with: .color(midBar ? t.primary : colors[min(2, i * 3 / n)].opacity(0.85)))
        }
    }
}

/// A visualizer that subscribes to the feed while on screen, with optional track info.
@MainActor
struct LiveVisualizer: View {
    let hub: VisualizerHub
    var prefsOverride: VisualizerPrefs?
    @Environment(\.obsidian) private var t

    var body: some View {
        let prefs = prefsOverride ?? hub.session?.preferences.prefs.visualizer ?? VisualizerPrefs()
        let frame = hub.feed.frame
        VisualizerCanvas(frame: frame, prefs: prefs)
            .overlay(alignment: .bottomLeading) {
                if prefs.showTrackInfo && !frame.title.isEmpty {
                    GeometryReader { geo in
                        let scale = max(1, min(geo.size.width, geo.size.height) / 400)
                        VStack(alignment: .leading, spacing: 4 * scale) {
                            Text(frame.title).font(t.ui(22 * scale, .semibold)).oneLine()
                            HStack(spacing: 10 * scale) {
                                if !frame.artist.isEmpty { Text(frame.artist).oneLine() }
                                if frame.bpm > 0 { Text("\(Format.bpm(frame.bpm)) BPM").font(t.mono(13 * scale, .medium)).readout() }
                            }
                            .font(t.ui(15 * scale))
                            .foregroundStyle(Color.white.opacity(0.65))
                        }
                        .foregroundStyle(Color.white)
                        .padding(24 * scale)
                        .frame(maxWidth: geo.size.width * 0.7, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
            }
            .onAppear { hub.feed.acquire() }
            .onDisappear { hub.feed.release() }
    }
}

/// Fullscreen performance view: visuals only. Tap to show the style controls; they hide after 3 s.
@MainActor
public struct VisualizerStage: View {
    let hub: VisualizerHub
    var onClose: (() -> Void)?
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.obsidian) private var t

    public init(hub: VisualizerHub = .shared, onClose: (() -> Void)? = nil) {
        self.hub = hub
        self.onClose = onClose
    }

    public var body: some View {
        ZStack(alignment: .top) {
            LiveVisualizer(hub: hub).ignoresSafeArea()
            if controls, let session = hub.session {
                VisualizerControls(session: session, onClose: onClose)
                    .padding(t.pad)
                    .transition(.opacity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { showControls() }
        .onAppear { showControls() }
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = hub.session?.preferences.prefs.session.keepScreenOn ?? false
        }
        #endif
    }

    private func showControls() {
        withAnimation(.easeOut(duration: 0.2)) { controls = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { controls = false }
        }
    }
}

/// Style, palette and close, over the stage.
@MainActor
struct VisualizerControls: View {
    let session: DJSession
    var onClose: (() -> Void)?
    @Environment(\.obsidian) private var t

    var body: some View {
        let prefs = Binding(get: { session.preferences.prefs.visualizer }, set: { session.preferences.prefs.visualizer = $0 })
        HStack(spacing: 8) {
            Segmented(VisualizerStyle.allCases.map { ($0, $0.title) }, selection: prefs.style)
                .frame(maxWidth: 420)
            Segmented(VisualizerPalette.allCases.map { ($0, $0.title) }, selection: prefs.palette)
                .frame(maxWidth: 260)
            Spacer(minLength: 0)
            if let onClose {
                Button { onClose() } label: { Image(systemName: "xmark").frame(width: 20) }
                    .buttonStyle(ObsidianButtonStyle())
                    .accessibilityLabel("Close visualizer")
            }
        }
    }
}

/// The visualizer sheet opened from the decks: preview, settings, and where it can be shown.
@MainActor
struct VisualizerPanel: View {
    let session: DJSession
    @State private var fullscreen = false
    @Environment(\.obsidian) private var t
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        let hub = VisualizerHub.shared
        SettingsPage("Visualizer") {
            LiveVisualizer(hub: hub)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.border, lineWidth: 1))
            HStack(spacing: 8) {
                #if os(macOS)
                Button("OPEN WINDOW") { openWindow(id: VisualizerWindowID.value) }
                    .buttonStyle(ObsidianButtonStyle(prominent: true))
                Text("Drag the window to another display and choose View › Enter Full Screen.")
                    .font(t.ui(12)).foregroundStyle(t.textMuted).fixedSize(horizontal: false, vertical: true)
                #else
                Button("FULL SCREEN") { fullscreen = true }.buttonStyle(ObsidianButtonStyle(prominent: true))
                Text(hub.externalDisplayActive ? "Also showing on the external display." :
                        "Connect a display or AirPlay to an Apple TV to show it on a second screen.")
                    .font(t.ui(12)).foregroundStyle(t.textMuted).fixedSize(horizontal: false, vertical: true)
                #endif
            }
            VisualizerSettingsGroups(session: session)
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        #if os(iOS)
        .fullScreenCover(isPresented: $fullscreen) {
            VisualizerStage(hub: hub) { fullscreen = false }
                .environment(\.obsidian, t)
        }
        #endif
    }
}

/// Visualizer settings, shared by the panel and Settings.
@MainActor
struct VisualizerSettingsGroups: View {
    let session: DJSession

    var body: some View {
        let v = Binding(get: { session.preferences.prefs.visualizer }, set: { session.preferences.prefs.visualizer = $0 })
        SettingsGroup("Look") {
            SettingsChoice(title: "Style", divider: false, options: VisualizerStyle.allCases.map { ($0, $0.title) }, selection: v.style)
            SettingsChoice(title: "Colours", options: VisualizerPalette.allCases.map { ($0, $0.title) }, selection: v.palette)
            SettingsChoice(title: "Sensitivity", options: VisualizerPrefs.sensitivityChoices.map { ($0, String(format: "%g×", $0)) }, selection: v.sensitivity)
        }
        SettingsGroup("Behaviour", footer: "The visualizer reads the master output, so it shows exactly what the room hears. It never affects the audio.") {
            SettingsToggle(title: "Move with the beat", divider: false, isOn: v.beatReactive)
            SettingsToggle(title: "Show track title and BPM", isOn: v.showTrackInfo)
            #if os(iOS)
            SettingsToggle(title: "Use an external display", detail: "A connected display or an Apple TV via AirPlay shows the visualizer instead of mirroring the app.",
                           scope: .iOS, isOn: v.useExternalDisplay)
            #endif
        }
    }
}

/// The id of the macOS visualizer window (declared in the app).
public enum VisualizerWindowID {
    public static let value = "visualizer"
}

/// Root of the macOS visualizer window.
@MainActor
public struct VisualizerWindowRoot: View {
    @State private var store = AppearanceStore()
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        VisualizerStage(hub: .shared)
            .environment(\.obsidian, ObsidianTheme(appearance: store.appearance, systemIsDark: scheme == .dark))
            .frame(minWidth: 480, minHeight: 270)
    }
}

#if os(iOS)
/// Puts the visualizer on an external display or AirPlay screen instead of mirroring the app.
/// Wired up by `SoundboardAppDelegate`; the scene appears and disappears with the display.
public final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    public var window: UIWindow?

    public func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated {
            let hub = VisualizerHub.shared
            let window = UIWindow(windowScene: windowScene)
            let root = VisualizerStage(hub: hub)
                .environment(\.obsidian, ObsidianTheme(appearance: AppearanceStore().appearance, systemIsDark: true))
            window.rootViewController = UIHostingController(rootView: root)
            window.isHidden = false
            self.window = window
            hub.externalDisplayActive = true
        }
    }

    public func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated {
            VisualizerHub.shared.externalDisplayActive = false
            window = nil
        }
    }
}

/// App delegate that routes external-display scenes to `ExternalDisplaySceneDelegate` and leaves
/// the app's own window to SwiftUI. Use with `@UIApplicationDelegateAdaptor`.
public final class SoundboardAppDelegate: NSObject, UIApplicationDelegate {
    public func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                            options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Only the external display is ours; the app's own window stays SwiftUI's.
        guard connectingSceneSession.role == .windowExternalDisplayNonInteractive else {
            return connectingSceneSession.configuration
        }
        let config = UISceneConfiguration(name: "Visualizer", sessionRole: connectingSceneSession.role)
        // Setting off: no delegate, so iOS mirrors the app as usual.
        let wanted = MainActor.assumeIsolated {
            VisualizerHub.shared.session?.preferences.prefs.visualizer.useExternalDisplay ?? true
        }
        if wanted { config.delegateClass = ExternalDisplaySceneDelegate.self }
        return config
    }
}
#endif
