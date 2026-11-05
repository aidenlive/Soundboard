import AVFAudio
import Foundation
import SoundboardEngine

/// A decoded, analysed track ready to load on a deck. Wraps `sbe_track*`.
///
/// Decoding uses AVAudioFile (MP3, AAC, ALAC, WAV, AIFF, FLAC). DRM-protected or streaming
/// content is not file-decodable; streaming catalogues require a licensed partner SDK.
public final class Track: @unchecked Sendable {
    public struct Analysis: Sendable, Equatable, Codable {
        public var bpm: Double
        public var firstBeatFrame: Double
        public var tempoConfidence: Double
        public var keyIndex: Int
        public var keyName: String
        public var camelot: String
        public var loudnessLUFS: Double
        public var autoGainDB: Float
    }

    let handle: OpaquePointer
    public let frames: Int64
    public let sampleRate: Double
    public private(set) var analysis: Analysis?

    init(handle: OpaquePointer, frames: Int64, sampleRate: Double) {
        self.handle = handle
        self.frames = frames
        self.sampleRate = sampleRate
    }

    deinit { sbe_track_release(handle) }

    /// Wraps raw interleaved float PCM.
    public convenience init?(interleaved: [Float], channels: Int, sampleRate: Double) {
        let frames = Int64(interleaved.count / max(1, channels))
        guard let h = interleaved.withUnsafeBufferPointer({
            sbe_track_create($0.baseAddress, frames, Int32(channels), sampleRate)
        }) else { return nil }
        self.init(handle: h, frames: frames, sampleRate: sampleRate)
    }

    /// Decodes a file off the main thread.
    ///
    /// Reads in fixed-size chunks until the file reports end of data. `AVAudioFile.length` is only
    /// an estimate for some compressed files and is 0 for empty or truncated ones; a buffer sized
    /// from it can have zero capacity, which makes `read(into:)` abort the process with an
    /// assertion rather than throw.
    public static func decode(url: URL) async throws -> Track {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            let channels = Int(format.channelCount)
            let outChannels = max(1, min(channels, 2))
            guard channels > 0, format.sampleRate > 0 else { throw CocoaError(.fileReadCorruptFile) }

            let chunk: AVAudioFrameCount = 1 << 16
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var interleaved: [Float] = []
            interleaved.reserveCapacity(max(0, Int(file.length)) * outChannels)
            while true {
                try Task.checkCancellation()
                do {
                    try file.read(into: buffer, frameCount: chunk)
                } catch {
                    // A truncated file fails partway through: keep what decoded cleanly.
                    if interleaved.isEmpty { throw error }
                    break
                }
                let n = Int(buffer.frameLength)
                if n == 0 { break }
                guard let data = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
                let start = interleaved.count
                interleaved.append(contentsOf: repeatElement(0, count: n * outChannels))
                interleaved.withUnsafeMutableBufferPointer { out in
                    for c in 0..<outChannels {
                        let src = data[c]
                        for i in 0..<n { out[start + i * outChannels + c] = src[i] }
                    }
                }
            }
            // A file with no audio frames is not a track.
            guard !interleaved.isEmpty,
                  let track = Track(interleaved: interleaved, channels: outChannels, sampleRate: format.sampleRate) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return track
        }.value
    }

    /// Tempo/beat grid, key and loudness. Slow (≈ 0.1–0.5 s per minute of audio): call off the main thread.
    /// Must run before the track is loaded on a deck.
    @discardableResult
    public func analyze(minBPM: Double = 78, targetLUFS: Double = -10) -> Analysis {
        var a = sbe_track_analysis()
        sbe_track_analyze(handle, minBPM, targetLUFS, &a)
        let key = withUnsafeBytes(of: a.key_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let camelot = withUnsafeBytes(of: a.camelot) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let result = Analysis(bpm: a.bpm, firstBeatFrame: a.first_beat_frame, tempoConfidence: a.tempo_confidence,
                              keyIndex: Int(a.key_index), keyName: key, camelot: camelot,
                              loudnessLUFS: a.loudness_lufs, autoGainDB: a.auto_gain_db)
        analysis = result
        return result
    }

    /// Re-apply a previously computed analysis without re-running it (call before loading).
    public func apply(_ a: Analysis) {
        sbe_track_set_grid(handle, a.bpm, a.firstBeatFrame)
        sbe_track_set_auto_gain(handle, a.autoGainDB)
        analysis = a
    }

    /// Three-band waveform overview for drawing.
    public func waveform(framesPerBin: Int) -> [sbe_waveform_bin] {
        let count = Int(sbe_track_waveform(handle, Int32(framesPerBin), nil, 0))
        var bins = [sbe_waveform_bin](repeating: sbe_waveform_bin(), count: count)
        let n = bins.withUnsafeMutableBufferPointer { sbe_track_waveform(handle, Int32(framesPerBin), $0.baseAddress, Int32(count)) }
        return Array(bins.prefix(Int(n)))
    }
}

public extension EngineHost {
    func load(_ track: Track, deck: Int) { sbe_deck_load(engine, Int32(deck), track.handle) }
    func preview(_ track: Track, from frame: Double = 0) {
        sbe_preview_load(engine, track.handle, frame)
        sbe_preview_play(engine)
    }
}
