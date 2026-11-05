import AVFAudio
import Foundation
import SoundboardEngine

/// A decoded, analysed track ready to load on a deck. Wraps `sbe_track*`.
///
/// Decoding uses AVAudioFile (MP3, AAC, ALAC, WAV, AIFF, FLAC). DRM-protected or streaming
/// content is not file-decodable; streaming catalogues require a licensed partner SDK.
public final class Track: @unchecked Sendable {
    public struct Analysis: Sendable {
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
    public static func decode(url: URL) async throws -> Track {
        try await Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            let total = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try file.read(into: buffer)
            let channels = Int(format.channelCount)
            let n = Int(buffer.frameLength)
            var interleaved = [Float](repeating: 0, count: n * max(1, min(channels, 2)))
            let outChannels = max(1, min(channels, 2))
            if let data = buffer.floatChannelData {
                for c in 0..<outChannels {
                    let src = data[c]
                    for i in 0..<n { interleaved[i * outChannels + c] = src[i] }
                }
            }
            guard let track = Track(interleaved: interleaved, channels: outChannels, sampleRate: format.sampleRate) else {
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
