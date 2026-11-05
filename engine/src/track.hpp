// Soundboard Engine — immutable decoded track data shared between threads.
#pragma once

#include <cmath>
#include <cstdint>
#include <memory>
#include <vector>

namespace sbe {

struct BeatGrid {
    double bpm = 0.0;             // 0 = unknown
    double firstBeatFrame = 0.0;  // in source frames

    bool valid() const { return bpm > 1.0; }
    double beatLength(double sampleRate) const { return 60.0 / bpm * sampleRate; }
    // Beat position (in beats, fractional) of a source frame.
    double beatAt(double frame, double sampleRate) const {
        return (frame - firstBeatFrame) / beatLength(sampleRate);
    }
    double frameOfBeat(double beat, double sampleRate) const {
        return firstBeatFrame + beat * beatLength(sampleRate);
    }
    double nearestBeatFrame(double frame, double sampleRate) const {
        return frameOfBeat(std::round(beatAt(frame, sampleRate)), sampleRate);
    }
};

// Decoded PCM, always stored as interleaved stereo float. Decoding (MP3/AAC/FLAC/ALAC) is
// done by the platform host with its native decoder, then handed to the engine.
struct AudioBuffer {
    std::vector<float> samples;  // interleaved L,R
    int64_t frames = 0;
    double sampleRate = 44100.0;
    BeatGrid grid;
    float autoGainDb = 0.0f;     // loudness-normalisation trim suggested by analysis

    static std::shared_ptr<AudioBuffer> fromInterleaved(const float* data, int64_t frames, int channels,
                                                        double sampleRate) {
        auto b = std::make_shared<AudioBuffer>();
        b->frames = frames;
        b->sampleRate = sampleRate;
        b->samples.resize(size_t(frames) * 2);
        for (int64_t i = 0; i < frames; ++i) {
            if (channels == 1) {
                b->samples[2 * i] = b->samples[2 * i + 1] = data[i];
            } else {
                b->samples[2 * i] = data[i * channels];
                b->samples[2 * i + 1] = data[i * channels + 1];
            }
        }
        return b;
    }
};

using TrackRef = std::shared_ptr<const AudioBuffer>;

}  // namespace sbe
