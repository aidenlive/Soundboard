import SwiftUI
import SoundboardUI

@main
struct SoundboardApp: App {
    #if os(iOS)
    // Routes an external display or AirPlay screen to the visualizer instead of mirroring.
    @UIApplicationDelegateAdaptor(SoundboardAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            SoundboardRootView()
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 600)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif

        #if os(macOS)
        // A separate window, so the visualizer can go full screen on a second display while the
        // decks stay on the first.
        Window("Visualizer", id: VisualizerWindowID.value) {
            VisualizerWindowRoot()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        #endif
    }
}
