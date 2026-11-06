import AVFoundation
import CoreMedia
import Foundation
import SoundboardEngine

/// A decoded, analysed track ready to load on a deck. Wraps `sbe_track*`.
///
/// Decoding: see `decode(url:)`. DRM-protected or streaming content is not file-decodable;
/// streaming catalogues require a licensed partner SDK.
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
    /// Two decoders, tried in order:
    ///  1. `AVAudioFile`: fast, and handles WAV, AIFF, CAF, MP3, AAC/ALAC in M4A, FLAC.
    ///  2. `AVAssetReader`: anything AVFoundation plays, including M4A/MP4 files that AVAudioFile
    ///     rejects (multiple tracks, video tracks, unusual atoms, HE-AAC) and files whose reported
    ///     length is wrong.
    /// DRM-protected files (Apple Music downloads, `.m4p`) cannot be decoded by any app and get
    /// their own error. Both decoders read in chunks until end of data, because a buffer sized
    /// from a reported length of 0 makes AVFoundation abort the process.
    public static func decode(url: URL) async throws -> Track {
        try await Task.detached(priority: .userInitiated) {
            let pcm: (samples: [Float], channels: Int, rate: Double)
            do {
                pcm = try decodeWithAudioFile(url)
            } catch {
                pcm = try await decodeWithAssetReader(url, firstError: error)
            }
            guard !pcm.samples.isEmpty,
                  let track = Track(interleaved: pcm.samples, channels: pcm.channels, sampleRate: pcm.rate) else {
                throw TrackDecodeError.noAudio
            }
            return track
        }.value
    }

    private static func decodeWithAudioFile(_ url: URL) throws -> (samples: [Float], channels: Int, rate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0, format.sampleRate > 0 else { throw TrackDecodeError.noAudio }
        let outChannels = min(channels, 2)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw TrackDecodeError.noAudio }
        var out: [Float] = []
        out.reserveCapacity(max(0, Int(file.length)) * outChannels)
        while true {
            try Task.checkCancellation()
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                if out.isEmpty { throw error }
                break   // truncated file: keep what decoded cleanly
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { throw TrackDecodeError.noAudio }
            appendInterleaved(&out, n: n, channels: outChannels) { c, i in data[c][i] }
        }
        if out.isEmpty { throw TrackDecodeError.noAudio }
        return (out, outChannels, format.sampleRate)
    }

    private static func decodeWithAssetReader(_ url: URL, firstError: Error) async throws -> (samples: [Float], channels: Int, rate: Double) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        if (try? await asset.load(.hasProtectedContent)) == true { throw TrackDecodeError.protected }
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TrackDecodeError.unreadable(firstError.localizedDescription)
        }
        var rate = 44_100.0, sourceChannels = 2
        if let desc = try await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            if asbd.mSampleRate > 0 { rate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { sourceChannels = Int(asbd.mChannelsPerFrame) }
        }
        let channels = min(sourceChannels, 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TrackDecodeError.unreadable(firstError.localizedDescription) }
        reader.add(output)
        guard reader.startReading() else {
            throw TrackDecodeError.unreadable(reader.error?.localizedDescription ?? firstError.localizedDescription)
        }
        var out: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes >= MemoryLayout<Float>.size else { continue }
            let start = out.count
            out.append(contentsOf: repeatElement(0, count: bytes / MemoryLayout<Float>.size))
            _ = out.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: (bytes / 4) * 4, destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        if reader.status == .failed, out.isEmpty {
            throw TrackDecodeError.unreadable(reader.error?.localizedDescription ?? firstError.localizedDescription)
        }
        if out.isEmpty { throw TrackDecodeError.noAudio }
        return (out, channels, rate)
    }

    private static func appendInterleaved(_ out: inout [Float], n: Int, channels: Int, _ sample: (Int, Int) -> Float) {
        let start = out.count
        out.append(contentsOf: repeatElement(0, count: n * channels))
        out.withUnsafeMutableBufferPointer { buf in
            for c in 0..<channels {
                for i in 0..<n { buf[start + i * channels + c] = sample(c, i) }
            }
        }
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

/// Why a file could not become a track, in words a DJ can act on.
public enum TrackDecodeError: LocalizedError, Equatable {
    case protected
    case noAudio
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .protected: "This file is copy-protected (an Apple Music download or .m4p). Only DRM-free files can be mixed."
        case .noAudio: "This file contains no audio."
        case .unreadable(let why): "This file can't be decoded: \(why)"
        }
    }
}
