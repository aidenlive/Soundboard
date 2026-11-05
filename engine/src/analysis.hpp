// Soundboard Engine — offline track analysis (runs on a background thread, never real-time).
#pragma once

#include <complex>
#include <cstdint>
#include <string>
#include <vector>

#include "track.hpp"

namespace sbe {

struct TempoOptions {
    double minBpm = 78.0;  // results are folded into [minBpm, 2 * minBpm)
    bool snapToInteger = true;
};

struct KeyResult {
    int index = -1;          // 0..11 major (C..B), 12..23 minor (Cm..Bm)
    std::string name;        // e.g. "A minor"
    std::string camelot;     // e.g. "8A"
    double confidence = 0;   // correlation margin to the runner-up
};

struct WaveformBin {
    float low = 0, mid = 0, high = 0, peak = 0;
};

struct Analysis {
    BeatGrid grid;
    double tempoConfidence = 0;
    KeyResult key;
    double loudnessLufs = -70;
    float autoGainDb = 0;
};

void fft(std::vector<std::complex<float>>& data, bool inverse = false);

// All functions take interleaved stereo float.
BeatGrid detectBeatGrid(const float* stereo, int64_t frames, double sampleRate,
                        const TempoOptions& opt = {}, double* confidence = nullptr);
KeyResult detectKey(const float* stereo, int64_t frames, double sampleRate);
double integratedLoudness(const float* stereo, int64_t frames, double sampleRate);  // ITU-R BS.1770-4
std::vector<WaveformBin> computeWaveform(const float* stereo, int64_t frames, double sampleRate,
                                         int framesPerBin);
Analysis analyzeTrack(const AudioBuffer& buffer, const TempoOptions& opt = {},
                      double targetLufs = -10.0);

std::string camelotForKey(int index);
std::string nameForKey(int index);
// Harmonic compatibility on the Camelot wheel (same, ±1, relative major/minor).
bool keysCompatible(int a, int b);

}  // namespace sbe
