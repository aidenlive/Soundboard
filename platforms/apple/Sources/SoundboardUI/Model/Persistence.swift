import CryptoKit
import Foundation

/// Where Soundboard keeps its data, and how it writes it.
///
/// ```
/// Application Support/Soundboard/
///   library.json          tracks (metadata, analysis, cue points, saved loop) and playlists
///   sessions/index.json   named sessions and the last one opened
///   sessions/<id>.json    one session: decks, mixer, queue, workspace
///   media/<id>.<ext>      audio copied in at import (always on iOS; optional on macOS)
/// ```
///
/// Every write is atomic (temp file + rename), so a crash never leaves half a file. A file that
/// fails to decode is moved aside as `<name>.corrupt-<timestamp>` rather than overwritten, and the
/// app starts with an empty one.
enum Storage {
    static let schemaVersion = 1

    static var root: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Soundboard", isDirectory: true)
    }

    static var media: URL { directory("media") }
    static var sessions: URL { directory("sessions") }
    static var libraryFile: URL { root.appendingPathComponent("library.json") }

    private static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #if os(iOS)
        // Imported audio is the user's content: back it up, but never let iOS purge it.
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var u = url
        try? u.setResourceValues(values)
        #endif
        return url
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    /// Reads a file. Missing → nil. Unreadable → moved aside, nil, and `quarantined` set.
    static func read<T: Decodable>(_ type: T.Type, from url: URL, quarantined: inout Bool) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: aside)
            quarantined = true
            return nil
        }
    }

    /// Bytes used by copied-in audio.
    static func mediaBytes() -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: keys) else { return 0 }
        return files.reduce(0) { total, url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return total + Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
    }
}

enum ContentHash {
    /// SHA-256 of a file, streamed in 1 MB chunks. Identifies the same audio imported twice.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Limits how many imports decode and analyse at once (each holds a whole track in memory).
actor WorkLimiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}
