// Minimal RIFF/WAVE reader/writer used by tests and the routing prototype.
// Product builds decode with the platform's native decoders (AVAudioFile, MediaCodec).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace sbe {

struct WavData {
    int channels = 0;
    double sampleRate = 0;
    std::vector<float> samples;  // interleaved
    int64_t frames() const { return channels ? int64_t(samples.size()) / channels : 0; }
};

bool readWav(const std::string& path, WavData& out, std::string* error = nullptr);
// bits = 16, 24 or 32 (32 = IEEE float).
bool writeWav(const std::string& path, const WavData& data, int bits = 32);

}  // namespace sbe
