import AVFoundation
import Foundation
import SoundboardAudio

/// One track in the library. PCM is not kept: a track is decoded again when loaded on a deck,
/// so the library costs a few hundred kB per track (analysis + waveform), not tens of MB.
public struct LibraryTrack: Identifiable, Equatable {
    public enum State: Equatable { case analysing, ready, failed(String) }

    public let id: UUID
    public var title: String
    public var artist: String
    public var url: URL
    public var bookmark: Data?
    public var duration: Double = 0
    public var analysis: Track.Analysis?
    public var waveform: WaveformData = .empty
    public var state: State = .analysing

    public var facts: TrackFacts? {
        guard let a = analysis, a.bpm > 0 else { return nil }
        return TrackFacts(bpm: a.bpm, keyIndex: a.keyIndex, loudnessLUFS: a.loudnessLUFS)
    }

    /// Re-open a file the user picked earlier (security-scoped on iOS and in the macOS sandbox).
    func resolvedURL() -> URL {
        guard let bookmark else { return url }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        return (try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)) ?? url
    }
}

enum LibraryIO {
    static func bookmark(for url: URL) -> Data? {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        #endif
        return try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Title and artist from the file's metadata, falling back to the file name.
    static func metadata(for url: URL) async -> (title: String, artist: String, duration: Double) {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var duration = 0.0
        if let items = try? await asset.load(.commonMetadata) {
            if let t = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierTitle).first,
               let s = try? await t.load(.stringValue), !s.isEmpty { title = s }
            if let a = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtist).first,
               let s = try? await a.load(.stringValue) { artist = s }
        }
        if let d = try? await asset.load(.duration) { duration = d.seconds.isFinite ? d.seconds : 0 }
        return (title, artist, duration)
    }

    struct Analysed: Sendable {
        var analysis: Track.Analysis
        var low: [Float], mid: [Float], high: [Float]
        var framesPerBin: Int
        var sampleRate: Double
        var duration: Double
    }

    /// Decode → analyse → three-band waveform, off the main thread.
    static func analyse(url: URL) async throws -> Analysed {
        let track = try await Track.decode(url: url)
        return await Task.detached(priority: .utility) {
            let a = track.analyze()
            let framesPerBin = max(1, Int(track.sampleRate / 150))   // 150 bins per second
            let bins = track.waveform(framesPerBin: framesPerBin)
            func norm(_ v: [Float]) -> [Float] {
                let m = max(v.max() ?? 1, 1e-4)
                return v.map { min(1, $0 / m) }
            }
            return Analysed(analysis: a, low: norm(bins.map(\.low)), mid: norm(bins.map(\.mid)), high: norm(bins.map(\.high)),
                            framesPerBin: framesPerBin, sampleRate: track.sampleRate,
                            duration: Double(track.frames) / track.sampleRate)
        }.value
    }
}
