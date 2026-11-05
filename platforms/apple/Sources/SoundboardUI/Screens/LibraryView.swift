import SwiftUI
import SoundboardAudio

/// Library: what plays well next, then everything. Hold the headphones button to preview
/// a track privately (never on the speakers); tap A or B to load it.
@MainActor
struct LibraryView: View {
    let session: DJSession
    @Environment(\.obsidian) private var t
    @Environment(\.appActions) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library").font(t.ui(26, .semibold)).foregroundStyle(t.text)
                Spacer()
                Button("ADD MUSIC") { actions.importMusic() }.buttonStyle(ObsidianButtonStyle())
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 20) }
                    .buttonStyle(ObsidianButtonStyle())
                    .accessibilityLabel("Close")
            }
            .padding(t.pad)
            TextField("Search", text: $query)
                .font(t.ui(15))
                .padding(10)
                .background(t.surface)
                .clipShape(RoundedRectangle(cornerRadius: t.radius))
                .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(t.border, lineWidth: 1))
                .padding(.horizontal, t.pad)
            if session.analysingCount > 0 {
                HStack(spacing: 10) {
                    Pulse(bars: 9).frame(width: 28, height: 28)
                    Text("Analysing \(session.analysingCount) — BPM · KEY · LOUDNESS").font(t.mono(11)).foregroundStyle(t.textMuted)
                    Spacer()
                }
                .padding(.horizontal, t.pad).padding(.top, 10)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let next = session.upNext.prefix(3).filter { $0.match.score > 0 }
                    if query.isEmpty && !next.isEmpty {
                        Eyebrow("Plays well next").padding(.horizontal, t.pad).padding(.top, 16).padding(.bottom, 6)
                        ForEach(next, id: \.track.id) { item in
                            LibraryRow(session: session, track: item.track, match: item.match)
                        }
                    }
                    Eyebrow("All tracks").padding(.horizontal, t.pad).padding(.top, 16).padding(.bottom, 6)
                    ForEach(filtered) { track in
                        LibraryRow(session: session, track: track, match: nil)
                    }
                    if session.library.isEmpty {
                        Text("No music yet. Add songs from Files to start.")
                            .font(t.ui(14)).foregroundStyle(t.textSecondary).padding(t.pad)
                    }
                }
            }
        }
        .background(t.background)
    }

    private var filtered: [LibraryTrack] {
        guard !query.isEmpty else { return session.library }
        return session.library.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
    }
}

@MainActor
struct LibraryRow: View {
    let session: DJSession
    let track: LibraryTrack
    let match: TrackMatcher.Match?
    @Environment(\.obsidian) private var t
    @State private var previewing = false

    var body: some View {
        let playing = session.decks.contains { $0.trackID == track.id && $0.playing }
        HStack(spacing: 12) {
            Group {
                if playing {
                    Pulse(bars: 5, color: t.primary, accent: t.primary)
                } else if track.state == .analysing {
                    Pulse(bars: 5, animated: true)
                } else {
                    Color.clear
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(t.ui(14, .semibold)).foregroundStyle(playing ? t.primary : t.text).lineLimit(1)
                HStack(spacing: 8) {
                    Text(track.artist.isEmpty ? Format.time(track.duration) : track.artist).lineLimit(1)
                    if let m = match, m.harmony == .same || m.harmony == .compatible {
                        Label("harmonic", systemImage: "checkmark").labelStyle(CompactLabel()).foregroundStyle(t.success)
                    }
                    if case .failed(let why) = track.state { Text(why).foregroundStyle(t.error).lineLimit(1) }
                }
                .font(t.ui(12)).foregroundStyle(t.textMuted)
            }
            Spacer()
            if let a = track.analysis {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.bpm(a.bpm)).font(t.mono(12)).foregroundStyle(t.textSecondary)
                    Text(a.camelot).font(t.mono(11)).foregroundStyle(t.textMuted)
                }
            }
            if track.state == .ready {
                previewButton
                ForEach(0..<2, id: \.self) { i in
                    Button(i == 0 ? "A" : "B") { Task { await session.load(track.id, deck: i) } }
                        .buttonStyle(ObsidianButtonStyle())
                        .accessibilityLabel("Load on deck \(i == 0 ? "A" : "B")")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(t.border).frame(height: 1) }
    }

    /// Press and hold to hear the track in the headphones only.
    private var previewButton: some View {
        Image(systemName: "headphones")
            .frame(width: 44, height: 44)
            .foregroundStyle(previewing ? t.onPrimary : (session.cueAvailable ? t.text : t.textMuted))
            .background(previewing ? t.primary : t.surface)
            .clipShape(RoundedRectangle(cornerRadius: t.radius))
            .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(t.border, lineWidth: 1))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard session.cueAvailable, !previewing else { return }
                    previewing = true
                    Task { await session.preview(track.id) }
                }
                .onEnded { _ in
                    guard previewing else { return }
                    previewing = false
                    session.stopPreview()
                })
            .accessibilityLabel("Preview in headphones")
            .accessibilityHint(session.cueAvailable ? "Hold to listen privately" : "Connect headphones through a splitter cable or audio interface to preview")
            .accessibilityAddTraits(.isButton)
    }
}
