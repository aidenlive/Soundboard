import SwiftUI
import SoundboardAudio

/// Library: all tracks, the session's queue, and playlists. Hold the headphones button to preview
/// a track privately (never on the speakers); tap A or B to load it. Everything else (queue,
/// playlists, re-analyse, remove) is in each row's menu, its swipe actions, or selection mode.
@MainActor
struct LibraryView: View {
    @Bindable var session: DJSession
    @Environment(\.obsidian) private var t
    @Environment(\.appActions) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var confirmRemove: Set<UUID> = []
    @State private var naming: NamingTarget?
    @State private var nameDraft = ""

    enum NamingTarget: Identifiable, Equatable {
        case newPlaylist(with: [UUID]), rename(UUID)
        var id: String {
            switch self {
            case .newPlaylist: "new"
            case .rename(let id): id.uuidString
            }
        }
    }

    private var library: LibraryStore { session.library }

    var body: some View {
        VStack(spacing: 0) {
            header
            sourceBar
            searchAndSort
            if library.busyCount > 0 {
                HStack(spacing: 10) {
                    Pulse(bars: 9).frame(width: 24, height: 24)
                    Text("Analysing \(library.busyCount) · BPM · KEY · LOUDNESS")
                        .font(t.mono(11)).foregroundStyle(t.textMuted).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, t.pad).padding(.top, 8)
            }
            if let notice = library.notice {
                NoticeBar(text: notice) { library.notice = nil }.padding(.horizontal, t.pad).padding(.top, 8)
            }
            list
            if selecting { selectionBar }
        }
        .background(t.background)
        .confirmationDialog(removeTitle, isPresented: Binding(get: { !confirmRemove.isEmpty }, set: { if !$0 { confirmRemove = [] } }),
                            titleVisibility: .visible) {
            Button("Remove from library", role: .destructive) {
                library.remove(confirmRemove)
                selection.subtract(confirmRemove)
                confirmRemove = []
            }
        } message: {
            Text(removeMessage)
        }
        .alert(namingTitle,
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) { naming = nil }
            Button("Save") { commitName() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Library").font(t.ui(26, .semibold)).foregroundStyle(t.text).lineLimit(1)
            Spacer(minLength: 8)
            Button(selecting ? "DONE" : "SELECT") {
                selecting.toggle()
                selection = []
            }
            .buttonStyle(ObsidianButtonStyle())
            .disabled(visibleTracks.isEmpty && !selecting)
            Button("ADD MUSIC") { actions.importMusic() }.buttonStyle(ObsidianButtonStyle(prominent: true))
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 20) }
                .buttonStyle(ObsidianButtonStyle())
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, t.pad).padding(.top, t.pad).padding(.bottom, 10)
    }

    private var sourceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                sourceChip("All tracks", count: library.tracks.count, source: .all)
                sourceChip("Queue", count: session.queue.count, source: .queue)
                ForEach(library.playlists) { p in
                    sourceChip(p.name, count: p.trackIDs.count, source: .playlist(p.id))
                        .contextMenu {
                            Button { nameDraft = p.name; naming = .rename(p.id) } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) {
                                if session.workspace.librarySource == .playlist(p.id) { session.workspace.librarySource = .all }
                                library.deletePlaylist(p.id)
                            } label: { Label("Delete playlist", systemImage: "trash") }
                        }
                }
                Button { nameDraft = ""; naming = .newPlaylist(with: []) } label: {
                    Label("Playlist", systemImage: "plus").labelStyle(CompactLabel())
                        .font(t.mono(11, .medium)).tracking(0.6)
                        .padding(.horizontal, 10).frame(minHeight: 32)
                        .foregroundStyle(t.textSecondary)
                        .overlay(Capsule().strokeBorder(t.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New playlist")
            }
            .padding(.horizontal, t.pad)
        }
    }

    private func sourceChip(_ title: String, count: Int, source: LibrarySource) -> some View {
        let on = session.workspace.librarySource == source
        return Button { session.workspace.librarySource = source; selection = [] } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160)
                Text("\(count)").monospacedDigit().foregroundStyle(on ? t.onPrimary.opacity(0.7) : t.textMuted)
            }
            .font(t.ui(13, .medium))
            .padding(.horizontal, 12).frame(minHeight: 32)
            .foregroundStyle(on ? t.onPrimary : t.text)
            .background(on ? t.primary : t.surface)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : t.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var searchAndSort: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(t.textMuted)
                TextField("Search title or artist", text: $query)
                    .font(t.ui(15))
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(t.textMuted) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).frame(minHeight: 40)
            .background(t.surface)
            .clipShape(RoundedRectangle(cornerRadius: t.radius))
            .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(t.border, lineWidth: 1))
            if session.workspace.librarySource != .queue {
                Menu {
                    Picker("Sort", selection: $session.workspace.librarySort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").frame(width: 40, height: 40)
                        .foregroundStyle(t.textSecondary)
                        .background(t.surface).clipShape(RoundedRectangle(cornerRadius: t.radius))
                        .overlay(RoundedRectangle(cornerRadius: t.radius).stroke(t.border, lineWidth: 1))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .accessibilityLabel("Sort by \(session.workspace.librarySort.title)")
            }
        }
        .padding(.horizontal, t.pad).padding(.top, 10)
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        let tracks = visibleTracks
        let source = session.workspace.librarySource
        List {
            if source == .all && query.isEmpty && !selecting {
                let next = session.upNext.filter { $0.match.score > 0 && !session.queue.contains($0.track.id) }.prefix(3)
                if !next.isEmpty {
                    Section {
                        ForEach(Array(next), id: \.track.id) { item in row(item.track, match: item.match) }
                    } header: { Eyebrow("Plays well next") }
                }
            }
            Section {
                ForEach(tracks) { track in row(track, match: nil) }
                    .onMove(perform: moveAction)
            } header: {
                if source == .all && query.isEmpty && !selecting { Eyebrow("All tracks") }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 52)
        .overlay {
            if tracks.isEmpty { emptyState(source) }
        }
    }

    @ViewBuilder private func row(_ track: LibraryTrack, match: TrackMatcher.Match?) -> some View {
        LibraryRow(session: session, track: track, match: match, selecting: selecting,
                   selected: selection.contains(track.id)) {
            if selection.contains(track.id) { selection.remove(track.id) } else { selection.insert(track.id) }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: t.pad, bottom: 0, trailing: t.pad))
        .listRowBackground(t.background)
        .listRowSeparatorTint(t.border)
        .contextMenu { menu(for: [track.id]) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            switch session.workspace.librarySource {
            case .queue:
                Button("Remove") { session.dequeue([track.id]) }.tint(t.textMuted)
            case .playlist(let pid):
                Button("Remove") { library.remove([track.id], fromPlaylist: pid) }.tint(t.textMuted)
            case .all:
                Button("Remove", role: .destructive) { confirmRemove = [track.id] }
            }
        }
        .swipeActions(edge: .leading) {
            if track.state == .ready && !session.queue.contains(track.id) {
                Button("Queue") { session.enqueue([track.id]) }.tint(t.primary)
            }
        }
    }

    @ViewBuilder private func menu(for ids: [UUID]) -> some View {
        let tracks = ids.compactMap { library.track($0) }
        let ready = tracks.filter { $0.state == .ready }
        if ids.count == 1, let one = ready.first {
            Button { Task { await session.load(one.id, deck: 0) } } label: { Label("Load on deck A", systemImage: "a.square") }
            Button { Task { await session.load(one.id, deck: 1) } } label: { Label("Load on deck B", systemImage: "b.square") }
        }
        if !ready.isEmpty {
            Button { session.enqueue(ready.map(\.id)) } label: { Label("Add to queue", systemImage: "text.badge.plus") }
        }
        Menu {
            ForEach(library.playlists) { p in
                Button(p.name) { library.add(ids, toPlaylist: p.id) }
            }
            Button { nameDraft = ""; naming = .newPlaylist(with: ids) } label: { Label("New playlist…", systemImage: "plus") }
        } label: { Label("Add to playlist", systemImage: "music.note.list") }
        switch session.workspace.librarySource {
        case .queue:
            Button { session.dequeue(Set(ids)) } label: { Label("Remove from queue", systemImage: "minus.circle") }
        case .playlist(let pid):
            Button { library.remove(Set(ids), fromPlaylist: pid) } label: { Label("Remove from playlist", systemImage: "minus.circle") }
        case .all:
            EmptyView()
        }
        if tracks.contains(where: { $0.state != .missing && !$0.isBusy }) {
            Button { for id in ids { library.analyse(id) } } label: { Label("Analyse again", systemImage: "waveform.badge.magnifyingglass") }
        }
        Divider()
        Button(role: .destructive) { confirmRemove = Set(ids) } label: { Label("Remove from library…", systemImage: "trash") }
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Text("\(selection.count) selected").font(t.mono(11, .medium)).foregroundStyle(t.textSecondary).lineLimit(1)
            Spacer(minLength: 4)
            Menu { menu(for: Array(selection)) } label: {
                Text("ACTIONS").font(t.mono(11, .semibold)).tracking(0.8)
                    .padding(.horizontal, 14).frame(minHeight: 40)
                    .foregroundStyle(t.onPrimary).background(t.primary).clipShape(RoundedRectangle(cornerRadius: t.radius))
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .disabled(selection.isEmpty)
            Button(selection.count == visibleTracks.count ? "NONE" : "ALL") {
                selection = selection.count == visibleTracks.count ? [] : Set(visibleTracks.map(\.id))
            }
            .buttonStyle(ObsidianButtonStyle())
        }
        .padding(.horizontal, t.pad).padding(.vertical, 10)
        .background(t.surface)
        .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
    }

    @ViewBuilder private func emptyState(_ source: LibrarySource) -> some View {
        VStack(spacing: 10) {
            switch source {
            case _ where !query.isEmpty:
                Text("Nothing matches “\(query)”.").font(t.ui(15, .medium))
            case .all:
                Text("No music yet").font(t.ui(17, .semibold))
                Text("Add songs from Files. MP3, M4A (AAC or ALAC), WAV, AIFF and FLAC all work.")
                    .font(t.ui(14)).foregroundStyle(t.textSecondary).multilineTextAlignment(.center)
                Button("ADD MUSIC") { actions.importMusic() }.buttonStyle(ObsidianButtonStyle(prominent: true))
            case .queue:
                Text("The queue is empty").font(t.ui(17, .semibold))
                Text("Swipe right on a track, or use its menu, to queue it. Mix plays the queue before suggestions.")
                    .font(t.ui(14)).foregroundStyle(t.textSecondary).multilineTextAlignment(.center)
            case .playlist:
                Text("This playlist is empty").font(t.ui(17, .semibold))
                Text("Add tracks from All tracks with their menu.").font(t.ui(14)).foregroundStyle(t.textSecondary)
            }
        }
        .foregroundStyle(t.text)
        .frame(maxWidth: 320)
        .padding(t.pad)
    }

    // MARK: Data

    private var visibleTracks: [LibraryTrack] {
        let base: [LibraryTrack]
        switch session.workspace.librarySource {
        case .all: base = sorted(library.tracks)
        case .queue: base = session.queue.compactMap { library.track($0) }
        case .playlist(let pid): base = library.tracks(in: pid)
        }
        guard !query.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
    }

    private func sorted(_ tracks: [LibraryTrack]) -> [LibraryTrack] {
        switch session.workspace.librarySort {
        case .added: tracks.sorted { $0.addedAt > $1.addedAt }
        case .title: tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: tracks.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .bpm: tracks.sorted { ($0.analysis?.bpm ?? .infinity) < ($1.analysis?.bpm ?? .infinity) }
        case .key: tracks.sorted { ($0.analysis?.camelot ?? "~").localizedStandardCompare($1.analysis?.camelot ?? "~") == .orderedAscending }
        }
    }

    /// Order matters in the queue and in playlists; drag to reorder there.
    private var movable: Bool {
        guard query.isEmpty, !selecting else { return false }
        if case .all = session.workspace.librarySource { return false }
        return true
    }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard movable else { return nil }
        return { from, to in move(from, to) }
    }

    private func move(_ from: IndexSet, _ to: Int) {
        switch session.workspace.librarySource {
        case .queue: session.moveQueue(from: from, to: to)
        case .playlist(let pid): library.movePlaylistTracks(pid, from: from, to: to)
        case .all: break
        }
    }

    private var removeTitle: String {
        confirmRemove.count == 1 ? "Remove “\(library.track(confirmRemove.first)?.title ?? "track")”?" : "Remove \(confirmRemove.count) tracks?"
    }

    private var removeMessage: String {
        let loaded = session.decks.contains { d in d.trackID.map(confirmRemove.contains) ?? false }
        var text = "Removes them from the library, every playlist and the queue, with their cue points."
        if loaded { text += " A deck playing one of them is ejected." }
        #if os(macOS)
        text += " Files you added from your Mac are not deleted."
        #endif
        return text
    }

    private var namingTitle: String {
        if case .rename = naming { return "Rename playlist" }
        return "New playlist"
    }

    private func commitName() {
        switch naming {
        case .newPlaylist(let ids):
            let id = library.createPlaylist(named: nameDraft.isEmpty ? "New playlist" : nameDraft, with: ids)
            if ids.isEmpty { session.workspace.librarySource = .playlist(id) }
        case .rename(let id):
            library.renamePlaylist(id, to: nameDraft)
        case nil: break
        }
        naming = nil
        selecting = false
        selection = []
    }
}

/// A dismissible one-line message.
@MainActor
struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void
    @Environment(\.obsidian) private var t

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(t.textSecondary)
            Text(text).font(t.ui(13)).foregroundStyle(t.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { dismiss() } label: { Image(systemName: "xmark").imageScale(.small).foregroundStyle(t.textMuted) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: t.radius))
    }
}

@MainActor
struct LibraryRow: View {
    let session: DJSession
    let track: LibraryTrack
    let match: TrackMatcher.Match?
    var selecting = false
    var selected = false
    var toggleSelection: () -> Void = {}
    @Environment(\.obsidian) private var t
    @State private var previewing = false

    var body: some View {
        let playing = session.decks.contains { $0.trackID == track.id && $0.playing }
        let queued = session.queue.firstIndex(of: track.id)
        HStack(spacing: 10) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? t.primary : t.textMuted)
                    .frame(width: 24)
            } else {
                status(playing: playing).frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(t.ui(14, .semibold)).foregroundStyle(playing ? t.primary : t.text)
                    .lineLimit(1).truncationMode(.tail)
                subtitle(queued: queued)
                    .font(t.ui(12)).foregroundStyle(t.textMuted).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if let a = track.analysis, track.state == .ready {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.bpm(a.bpm)).font(t.mono(12)).foregroundStyle(t.textSecondary)
                    Text(a.camelot.isEmpty ? "—" : a.camelot).font(t.mono(11)).foregroundStyle(t.textMuted)
                }
                .fixedSize()
                .frame(minWidth: 48, alignment: .trailing)
            }
            if track.state == .ready && !selecting {
                previewButton
                ForEach(0..<2, id: \.self) { i in
                    Button(i == 0 ? "A" : "B") { Task { await session.load(track.id, deck: i) } }
                        .buttonStyle(ObsidianButtonStyle())
                        .fixedSize()
                        .accessibilityLabel("Load on deck \(i == 0 ? "A" : "B")")
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if selecting { toggleSelection() } }
        .accessibilityElement(children: selecting ? .combine : .contain)
        .accessibilityAddTraits(selecting && selected ? .isSelected : [])
    }

    @ViewBuilder private func status(playing: Bool) -> some View {
        switch track.state {
        case _ where playing: Pulse(bars: 5, color: t.primary, accent: t.primary)
        case .importing, .analysing: Pulse(bars: 5, animated: true)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(t.error)
        case .missing: Image(systemName: "questionmark.folder").foregroundStyle(t.warning)
        case .ready: Color.clear
        }
    }

    @ViewBuilder private func subtitle(queued: Int?) -> some View {
        switch track.state {
        case .failed(let why): Text(why).foregroundStyle(t.error)
        case .missing: Text("File missing. Remove it, or add it again.").foregroundStyle(t.warning)
        case .importing: Text("Copying…")
        case .analysing: Text("Analysing…")
        case .ready:
            HStack(spacing: 6) {
                if let q = queued { Text("Q\(q + 1)").font(t.mono(10, .semibold)).foregroundStyle(t.primary) }
                Text([track.artist, Format.duration(track.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                if let m = match, m.harmony == .same || m.harmony == .compatible {
                    Image(systemName: "checkmark").foregroundStyle(t.success).accessibilityLabel("harmonic")
                }
            }
        }
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
