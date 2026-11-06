import AVFoundation
import Foundation
import Observation
import SoundboardAudio

/// Where a track's audio lives.
public enum TrackLocation: Codable, Equatable, Sendable {
    /// Copied into `Storage.media` at import. Survives the original being moved or deleted.
    case library(fileName: String)
    /// The user's own file, reached through a security-scoped bookmark (macOS, copy turned off).
    case reference(bookmark: Data, path: String)
}

/// A loop saved with the track, restored (inactive) whenever the track loads.
public struct SavedLoop: Codable, Equatable, Sendable {
    public var inFrame: Double
    public var outFrame: Double
}

/// One track in the library. PCM is not kept: a track is decoded again when it loads on a deck,
/// and its waveform is drawn from that decode, so the library costs a few kB per track.
public struct LibraryTrack: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case importing, analysing, ready, failed(String), missing }

    public let id: UUID
    public var title: String
    public var artist: String
    public var duration: Double = 0
    public var location: TrackLocation?
    public var contentHash: String?
    public var analysis: Track.Analysis?
    public var hotCues: [Double] = Array(repeating: -1, count: 8)
    public var savedLoop: SavedLoop?
    public var addedAt = Date()
    public var state: State = .importing

    public var facts: TrackFacts? {
        guard let a = analysis, a.bpm > 0 else { return nil }
        return TrackFacts(bpm: a.bpm, keyIndex: a.keyIndex, loudnessLUFS: a.loudnessLUFS)
    }

    public var isBusy: Bool { state == .importing || state == .analysing }
    public var fileExtension: String {
        switch location {
        case .library(let name): (name as NSString).pathExtension.uppercased()
        case .reference(_, let path): (path as NSString).pathExtension.uppercased()
        case nil: ""
        }
    }
}

public struct Playlist: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var trackIDs: [UUID]

    public init(id: UUID = UUID(), name: String, trackIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
    }
}

/// The library on disk.
struct LibraryDocument: Codable {
    struct StoredTrack: Codable {
        var id: UUID
        var title: String
        var artist: String
        var duration: Double
        var location: TrackLocation
        var contentHash: String?
        var analysis: Track.Analysis?
        var hotCues: [Double]
        var savedLoop: SavedLoop?
        var addedAt: Date
    }
    var schema = Storage.schemaVersion
    var tracks: [StoredTrack] = []
    var playlists: [Playlist] = []
}

/// The music library: import, analysis, cue points, playlists, removal. Shared by every session.
@MainActor
@Observable
public final class LibraryStore {
    public private(set) var tracks: [LibraryTrack] = []
    public private(set) var playlists: [Playlist] = []
    /// One-line messages about the last import (duplicates, failures), cleared when read.
    public var notice: String?
    /// The library file could not be read and was set aside; the app started with an empty library.
    public private(set) var recoveredFromCorruption = false

    /// Called when a track is removed, so decks and queues can let go of it.
    @ObservationIgnored var onRemove: ((UUID) -> Void)?
    @ObservationIgnored private let limiter = WorkLimiter(limit: 2)
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init() {}

    // MARK: Loading and saving

    public func load() {
        var corrupt = false
        guard let doc = Storage.read(LibraryDocument.self, from: Storage.libraryFile, quarantined: &corrupt) else {
            recoveredFromCorruption = corrupt
            return
        }
        playlists = doc.playlists
        tracks = doc.tracks.map { s in
            var t = LibraryTrack(id: s.id, title: s.title, artist: s.artist)
            t.duration = s.duration
            t.location = s.location
            t.contentHash = s.contentHash
            t.analysis = s.analysis
            t.hotCues = s.hotCues.count == 8 ? s.hotCues : Array(repeating: -1, count: 8)
            t.savedLoop = s.savedLoop
            t.addedAt = s.addedAt
            t.state = Self.fileExists(s.location) ? (s.analysis == nil ? .analysing : .ready) : .missing
            return t
        }
        for t in tracks where t.state == .analysing { analyse(t.id) }
    }

    /// Writes the library about half a second after the last change.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        let doc = LibraryDocument(tracks: tracks.compactMap { t in
            guard let location = t.location, t.state != .importing else { return nil }
            return .init(id: t.id, title: t.title, artist: t.artist, duration: t.duration, location: location,
                         contentHash: t.contentHash, analysis: t.analysis, hotCues: t.hotCues,
                         savedLoop: t.savedLoop, addedAt: t.addedAt)
        }, playlists: playlists)
        do {
            try Storage.write(doc, to: Storage.libraryFile)
        } catch {
            notice = "Couldn't save the library: \(error.localizedDescription)"
        }
    }

    // MARK: Queries

    public func track(_ id: UUID?) -> LibraryTrack? {
        guard let id else { return nil }
        return tracks.first { $0.id == id }
    }

    public var busyCount: Int { tracks.filter(\.isBusy).count }
    public var readyTracks: [LibraryTrack] { tracks.filter { $0.state == .ready } }

    /// A URL the decoder can open. Call `startAccessingSecurityScopedResource()` on it.
    func url(for track: LibraryTrack) -> URL? {
        switch track.location {
        case .library(let name): return Storage.media.appendingPathComponent(name)
        case .reference(let bookmark, let path):
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            return (try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? URL(fileURLWithPath: path)
        case nil: return nil
        }
    }

    private static func fileExists(_ location: TrackLocation) -> Bool {
        switch location {
        case .library(let name): FileManager.default.fileExists(atPath: Storage.media.appendingPathComponent(name).path)
        case .reference: true   // resolved (and checked) when loaded
        }
    }

    // MARK: Import

    /// Imports picked files. Each is copied in (or bookmarked), de-duplicated by content hash,
    /// read for title and artist, then analysed for tempo, key and loudness, two at a time.
    public func importFiles(_ urls: [URL], copy: Bool) {
        for url in urls {
            var placeholder = LibraryTrack(id: UUID(), title: url.deletingPathExtension().lastPathComponent, artist: "")
            placeholder.state = .importing
            tracks.append(placeholder)
            let id = placeholder.id
            Task { await self.importOne(url, id: id, copy: copy) }
        }
    }

    private func importOne(_ url: URL, id: UUID, copy: Bool) async {
        do {
            let staged = try await LibraryIO.stage(url, id: id, copy: copy)
            if let existing = tracks.first(where: { $0.contentHash == staged.hash && $0.id != id }) {
                if case .library(let name) = staged.location {
                    try? FileManager.default.removeItem(at: Storage.media.appendingPathComponent(name))
                }
                tracks.removeAll { $0.id == id }
                notice = "“\(existing.title)” is already in the library."
                return
            }
            update(id) {
                $0.location = staged.location
                $0.contentHash = staged.hash
                $0.state = .analysing
            }
            guard let current = track(id), let readable = self.url(for: current) else { return }
            let meta = await LibraryIO.metadata(for: readable)
            update(id) { $0.title = meta.title; $0.artist = meta.artist; $0.duration = meta.duration }
            scheduleSave()
            analyse(id)
        } catch {
            update(id) { $0.state = .failed(LibraryIO.message(for: error)) }
        }
    }

    /// Runs (or re-runs) analysis for one track.
    public func analyse(_ id: UUID) {
        guard let t = track(id), let url = url(for: t) else { return }
        update(id) { $0.state = .analysing }
        Task {
            do {
                let analysis = try await limiter.run { try await LibraryIO.analyse(url: url) }
                update(id) {
                    $0.analysis = analysis.analysis
                    $0.duration = analysis.duration
                    $0.state = .ready
                }
                scheduleSave()
            } catch {
                update(id) { $0.state = .failed(LibraryIO.message(for: error)) }
            }
        }
    }

    public func reanalyseAll() {
        for t in tracks where t.state != .missing && !t.isBusy { analyse(t.id) }
    }

    // MARK: Editing

    func update(_ id: UUID, _ change: (inout LibraryTrack) -> Void) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        change(&tracks[i])
    }

    func setHotCues(_ id: UUID, _ cues: [Double]) {
        guard let t = track(id), t.hotCues != cues else { return }
        update(id) { $0.hotCues = cues }
        scheduleSave()
    }

    func setSavedLoop(_ id: UUID, _ loop: SavedLoop?) {
        guard let t = track(id), t.savedLoop != loop else { return }
        update(id) { $0.savedLoop = loop }
        scheduleSave()
    }

    /// Removes tracks from the library, every playlist, every deck and queue, and deletes copies
    /// made at import. The user's own files (references) are never touched.
    public func remove(_ ids: Set<UUID>) {
        for id in ids {
            onRemove?(id)
            if let t = track(id), case .library(let name) = t.location {
                try? FileManager.default.removeItem(at: Storage.media.appendingPathComponent(name))
            }
        }
        tracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
        scheduleSave()
    }

    public func removeAll() { remove(Set(tracks.map(\.id))) }

    public func removeMissing() { remove(Set(tracks.filter { $0.state == .missing }.map(\.id))) }

    // MARK: Playlists

    @discardableResult
    public func createPlaylist(named name: String, with ids: [UUID] = []) -> UUID {
        let p = Playlist(name: Self.uniqueName(name, among: playlists.map(\.name)), trackIDs: ids)
        playlists.append(p)
        scheduleSave()
        return p.id
    }

    public func renamePlaylist(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = clean
        scheduleSave()
    }

    public func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        scheduleSave()
    }

    public func add(_ ids: [UUID], toPlaylist pid: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == pid }) else { return }
        for id in ids where !playlists[i].trackIDs.contains(id) { playlists[i].trackIDs.append(id) }
        scheduleSave()
    }

    public func remove(_ ids: Set<UUID>, fromPlaylist pid: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == pid }) else { return }
        playlists[i].trackIDs.removeAll { ids.contains($0) }
        scheduleSave()
    }

    public func movePlaylistTracks(_ pid: UUID, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == pid }) else { return }
        playlists[i].trackIDs.move(fromOffsets: from, toOffset: to)
        scheduleSave()
    }

    public func tracks(in pid: UUID) -> [LibraryTrack] {
        guard let p = playlists.first(where: { $0.id == pid }) else { return [] }
        return p.trackIDs.compactMap { track($0) }
    }

    static func uniqueName(_ base: String, among names: [String]) -> String {
        let clean = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = clean.isEmpty ? "Untitled" : clean
        guard names.contains(root) else { return root }
        var n = 2
        while names.contains("\(root) \(n)") { n += 1 }
        return "\(root) \(n)"
    }
}

enum LibraryIO {
    struct Staged: Sendable {
        var location: TrackLocation
        var hash: String
    }

    /// Makes a picked file durable. Runs under a file coordinator, which downloads iCloud
    /// placeholders and waits for other writers, while the picker's security scope is active.
    /// Copy mode puts the audio in `Storage.media`; reference mode keeps a security-scoped bookmark.
    static func stage(_ url: URL, id: UUID, copy: Bool) async throws -> Staged {
        let media = Storage.media
        return try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<Staged, Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
                do {
                    let hash = try ContentHash.sha256(of: readable)
                    if copy {
                        let ext = readable.pathExtension.lowercased()
                        let name = "\(id.uuidString).\(ext.isEmpty ? "audio" : ext)"
                        let dest = media.appendingPathComponent(name)
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.copyItem(at: readable, to: dest)
                        result = .success(Staged(location: .library(fileName: name), hash: hash))
                    } else {
                        #if os(macOS)
                        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                        #else
                        let options: URL.BookmarkCreationOptions = []
                        #endif
                        let bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
                        result = .success(Staged(location: .reference(bookmark: bookmark, path: url.path), hash: hash))
                    }
                } catch {
                    result = .failure(error)
                }
            }
            if let coordinationError { throw coordinationError }
            return try result.get()
        }.value
    }

    /// Title and artist from the file's metadata, falling back to the file name.
    static func metadata(for url: URL) async -> (title: String, artist: String, duration: Double) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var duration = 0.0
        if let items = try? await asset.load(.commonMetadata) {
            if let t = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle).first,
               let s = try? await t.load(.stringValue), !s.trimmingCharacters(in: .whitespaces).isEmpty { title = s }
            if let a = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtist).first,
               let s = try? await a.load(.stringValue) { artist = s }
        }
        if let d = try? await asset.load(.duration) { duration = d.seconds.isFinite ? d.seconds : 0 }
        // A copied file is named by its UUID; never show that as a title.
        if UUID(uuidString: title) != nil { title = "Untitled" }
        return (title, artist, duration)
    }

    struct Analysed: Sendable {
        var analysis: Track.Analysis
        var duration: Double
    }

    /// Decode → analyse, off the main thread.
    static func analyse(url: URL) async throws -> Analysed {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let track = try await Track.decode(url: url)
        return await Task.detached(priority: .utility) {
            let a = track.analyze()
            return Analysed(analysis: a, duration: Double(track.frames) / track.sampleRate)
        }.value
    }

    /// Normalised waveform for drawing, from an already decoded track (≈ 10 ms per minute).
    static func waveform(of track: Track) -> WaveformData {
        let framesPerBin = max(1, Int(track.sampleRate / 150))   // 150 bins per second
        let bins = track.waveform(framesPerBin: framesPerBin)
        func norm(_ v: [Float]) -> [Float] {
            let m = max(v.max() ?? 1, 1e-4)
            return v.map { min(1, $0 / m) }
        }
        return WaveformData(low: norm(bins.map(\.low)), mid: norm(bins.map(\.mid)), high: norm(bins.map(\.high)),
                            framesPerBin: framesPerBin, sampleRate: track.sampleRate)
    }

    /// A sentence for the library row.
    static func message(for error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription, error is TrackDecodeError { return d }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return "Soundboard wasn't given access to this file. Add it again from Files."
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return "The file is no longer there."
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return "Not enough storage to copy this file."
        }
        return ns.localizedDescription
    }
}
