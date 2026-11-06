import SwiftUI

/// The launch sequence, over the app while it starts.
///
/// 1. The Split mark, alone (0.25 s fade in, held for 0.6 s).
/// 2. If loading is still going: the mark fades out completely, then Pulse fades in at the same
///    size and centre. The two are never on screen together.
/// 3. When the session has restored, the overlay fades away.
///
/// If loading finishes during step 1 the app appears straight after the mark: Pulse only shows
/// when there is something to wait for. With Reduce Motion every change is instant.
@MainActor
struct LaunchView: View {
    /// Read live (a stored Bool would be stale inside the running task).
    let isReady: () -> Bool
    let finished: () -> Void
    @State private var stage: Stage = .mark
    @State private var markOpacity = 0.0
    @State private var pulseOpacity = 0.0
    @Environment(\.obsidian) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Stage { case mark, loading }

    /// One box for both marks, so they share size and centre exactly.
    private static let box: CGFloat = 88

    var body: some View {
        ZStack {
            t.background.ignoresSafeArea()
            Group {
                switch stage {
                case .mark: SplitMark().opacity(markOpacity)
                case .loading: Pulse(bars: 9, animated: !reduceMotion).opacity(pulseOpacity)
                }
            }
            .frame(width: Self.box, height: Self.box)
        }
        .accessibilityElement()
        .accessibilityLabel(stage == .mark ? "Soundboard" : "Loading your session")
        .task { await run() }
    }

    private func animate(_ seconds: Double, _ change: () -> Void) async {
        if reduceMotion {
            change()
            return
        }
        withAnimation(.easeInOut(duration: seconds)) { change() }
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func run() async {
        await animate(0.25) { markOpacity = 1 }
        try? await Task.sleep(for: .seconds(0.6))
        if !isReady() {
            await animate(0.2) { markOpacity = 0 }
            stage = .loading
            await animate(0.2) { pulseOpacity = 1 }
            while !isReady() { try? await Task.sleep(for: .milliseconds(50)) }
            // Let the pulse be seen, never flicker.
            try? await Task.sleep(for: .seconds(0.3))
        }
        finished()
    }
}
