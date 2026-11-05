import SwiftUI
import SoundboardUI

@main
struct SoundboardApp: App {
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
    }
}
