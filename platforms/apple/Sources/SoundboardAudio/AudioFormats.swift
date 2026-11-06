import Foundation
import UniformTypeIdentifiers

/// The audio files Soundboard imports. Everything here decodes through `Track.decode(url:)`.
public enum AudioFormats {
    /// Shown in the file picker. `.audio` covers most files; the explicit types catch files whose
    /// extension maps to a container type that does not conform to `public.audio` (for example an
    /// `.mp4` or `.m4v` that only carries sound).
    public static let importTypes: [UTType] = {
        var types: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .appleProtectedMPEG4Audio, .mpeg4Movie]
        for ext in ["m4a", "flac", "caf", "aac", "alac", "aifc", "ogg", "opus"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) { types.append(t) }
        }
        return types
    }()

    /// Extensions listed in Settings › Library.
    public static let supportedExtensions = ["mp3", "m4a", "aac", "alac", "wav", "aif", "aiff", "caf", "flac", "mp4"]
}
