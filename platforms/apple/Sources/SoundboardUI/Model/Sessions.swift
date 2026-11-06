import Foundation
import Observation

extension KeyedDecodingContainer {
    /// Decodes a key if present and valid, else the default: old files load in new versions.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        do { return try decodeIfPresent(T.self, forKey: key) ?? fallback } catch { return fallback }
    }
}

/// One deck as it was when the session was saved. Decks always restore paused.
public struct DeckSnapshot: Codable, Equatable, Sendable {
    public var trackID: UUID?
    public var position = 0.0
    public var tempo = 1.0
    public var syncLocked = false
    public var loop: SavedLoop?
    public var loopActive = false
    public var cueEnabled = false
    public var trim = 0.0, high = 0.0, mid = 0.0, low = 0.0, filter = 0.0, fader = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DeckSnapshot()
        trackID = c.value(.trackID, d.trackID)
        position = c.value(.position, d.position)
        tempo = c.value(.tempo, d.tempo)
        syncLocked = c.value(.syncLocked, d.syncLocked)
        loop = c.value(.loop, d.loop)
        loopActive = c.value(.loopActive, d.loopActive)
        cueEnabled = c.value(.cueEnabled, d.cueEnabled)
        trim = c.value(.trim, d.trim); high = c.value(.high, d.high); mid = c.value(.mid, d.mid)
        low = c.value(.low, d.low); filter = c.value(.filter, d.filter); fader = c.value(.fader, d.fader)
    }
}

public struct MixerSnapshot: Codable, Equatable, Sendable {
    /// −1 is deck A, the default for a new set (deck B silent until a transition).
    public var crossfader = -1.0
    public var masterVolume = 0.85
    public var headphoneVolume = 0.8
    public var cueMix = 0.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MixerSnapshot()
        crossfader = c.value(.crossfader, d.crossfader)
        masterVolume = c.value(.masterVolume, d.masterVolume)
        headphoneVolume = c.value(.headphoneVolume, d.headphoneVolume)
        cueMix = c.value(.cueMix, d.cueMix)
    }
}

/// What the library shows, and how it is sorted.
public enum LibrarySource: Codable, Hashable, Sendable {
    case all, queue, playlist(UUID)
}

public enum LibrarySort: String, Codable, CaseIterable, Identifiable, Sendable {
    case added, title, artist, bpm, key
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .added: "Recently added"
        case .title: "Title"
        case .artist: "Artist"
        case .bpm: "BPM"
        case .key: "Key"
        }
    }
}

/// The landscape layout: waveforms and the Mix button, or jog wheels and pitch faders.
public enum DeckMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case mix, dj
    public var id: String { rawValue }
    public var title: String { self == .mix ? "MIX" : "DJ" }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var librarySource: LibrarySource = .all
    public var librarySort: LibrarySort = .added
    public var deckMode: DeckMode = .mix

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        librarySource = c.value(.librarySource, .all)
        librarySort = c.value(.librarySort, .added)
        deckMode = c.value(.deckMode, .mix)
    }
}

public struct SessionDocument: Codable, Equatable, Sendable {
    public var schema = Storage.schemaVersion
    public var id: UUID
    public var decks: [DeckSnapshot] = [DeckSnapshot(), DeckSnapshot()]
    public var mixer = MixerSnapshot()
    public var queue: [UUID] = []
    public var workspace = WorkspaceSnapshot()

    public init(id: UUID) { self.id = id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = c.value(.schema, Storage.schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        let decks = c.value(.decks, [DeckSnapshot(), DeckSnapshot()])
        self.decks = decks.count >= 2 ? Array(decks.prefix(2)) : decks + Array(repeating: DeckSnapshot(), count: 2 - decks.count)
        mixer = c.value(.mixer, MixerSnapshot())
        queue = c.value(.queue, [])
        workspace = c.value(.workspace, WorkspaceSnapshot())
    }
}

public struct SessionInfo: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var created: Date
    public var modified: Date
}

struct SessionIndex: Codable {
    var schema = Storage.schemaVersion
    var sessions: [SessionInfo] = []
    var lastOpened: UUID?
}

/// Named sessions on disk. The running session itself lives in `DJSession`, which snapshots into
/// and restores from the documents kept here.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var sessions: [SessionInfo] = []
    public private(set) var currentID: UUID?
    @ObservationIgnored private var lastOpened: UUID?
    @ObservationIgnored private var lastWritten: [UUID: Data] = [:]

    public init() {}

    public var current: SessionInfo? { sessions.first { $0.id == currentID } }
    public var lastOpenedID: UUID? { lastOpened.flatMap { id in sessions.contains { $0.id == id } ? id : nil } }

    private var indexURL: URL { Storage.sessions.appendingPathComponent("index.json") }
    private func url(_ id: UUID) -> URL { Storage.sessions.appendingPathComponent("\(id.uuidString).json") }

    public func load() {
        var corrupt = false
        let index = Storage.read(SessionIndex.self, from: indexURL, quarantined: &corrupt) ?? SessionIndex()
        // Keep only sessions whose file exists.
        sessions = index.sessions.filter { FileManager.default.fileExists(atPath: url($0.id).path) }
        lastOpened = index.lastOpened
    }

    public func document(_ id: UUID) -> SessionDocument? {
        var corrupt = false
        return Storage.read(SessionDocument.self, from: url(id), quarantined: &corrupt)
    }

    /// Creates a session file and makes it current.
    @discardableResult
    public func create(named name: String, from doc: SessionDocument? = nil) -> SessionDocument {
        let id = UUID()
        var d = doc ?? SessionDocument(id: id)
        d.id = id
        let now = Date()
        sessions.append(SessionInfo(id: id, name: LibraryStore.uniqueName(name, among: sessions.map(\.name)), created: now, modified: now))
        write(d)
        open(id)
        return d
    }

    public func open(_ id: UUID) {
        currentID = id
        lastOpened = id
        writeIndex()
    }

    /// Writes the document if it changed since the last write. Returns whether it wrote.
    @discardableResult
    public func save(_ doc: SessionDocument) -> Bool {
        guard let data = try? Storage.encoder.encode(doc), lastWritten[doc.id] != data else { return false }
        write(doc)
        if let i = sessions.firstIndex(where: { $0.id == doc.id }) { sessions[i].modified = Date() }
        writeIndex()
        return true
    }

    public func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].name = LibraryStore.uniqueName(clean, among: sessions.filter { $0.id != id }.map(\.name))
        writeIndex()
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        sessions.removeAll { $0.id == id }
        lastWritten[id] = nil
        if lastOpened == id { lastOpened = sessions.max { $0.modified < $1.modified }?.id }
        if currentID == id { currentID = nil }
        writeIndex()
    }

    public func deleteAll() {
        for s in sessions { try? FileManager.default.removeItem(at: url(s.id)) }
        sessions = []
        lastWritten = [:]
        currentID = nil
        lastOpened = nil
        writeIndex()
    }

    private func write(_ doc: SessionDocument) {
        do {
            try Storage.write(doc, to: url(doc.id))
            lastWritten[doc.id] = try? Storage.encoder.encode(doc)
        } catch {
            // The next autosave tries again; the in-memory session is unaffected.
        }
    }

    private func writeIndex() {
        try? Storage.write(SessionIndex(sessions: sessions, lastOpened: lastOpened), to: indexURL)
    }
}
