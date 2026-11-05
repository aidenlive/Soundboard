// Deterministic synthetic test material: drum patterns, chord progressions, test tones.
// Lets the tests and the routing prototype run without any copyrighted audio.
#pragma once

#include <cmath>
#include <cstdint>
#include <memory>
#include <random>
#include <vector>

#include "track.hpp"

namespace sbe::synth {

constexpr double kTwoPi = 6.283185307179586;

inline double midiToHz(double m) { return 440.0 * std::pow(2.0, (m - 69.0) / 12.0); }

struct TrackSpec {
    double bpm = 124.0;
    double seconds = 30.0;
    double sampleRate = 44100.0;
    double firstBeatSeconds = 0.25;   // silence before the first kick
    std::vector<std::vector<int>> chords = {{57, 60, 64}, {53, 57, 60}, {55, 59, 62}, {52, 56, 59}};  // Am F G E
    int bassRootOffset = -24;
    float drums = 0.8f, bass = 0.5f, pads = 0.25f, hats = 0.15f;
    uint32_t seed = 1;
};

// A loop-based "club track": four-on-the-floor kick, off-beat hats, bassline, chord pads.
inline std::shared_ptr<AudioBuffer> makeTrack(const TrackSpec& s) {
    auto b = std::make_shared<AudioBuffer>();
    b->sampleRate = s.sampleRate;
    b->frames = int64_t(s.seconds * s.sampleRate);
    b->samples.assign(size_t(b->frames) * 2, 0.0f);
    const double beat = 60.0 / s.bpm;
    std::mt19937 rng(s.seed);
    std::uniform_real_distribution<float> noise(-1.0f, 1.0f);
    float hpState = 0, prevNoise = 0;
    for (int64_t i = 0; i < b->frames; ++i) {
        const double t = double(i) / s.sampleRate - s.firstBeatSeconds;
        double l = 0, r = 0;
        if (t >= 0) {
            const double beatPos = t / beat;
            const int beatIdx = int(beatPos);
            const double inBeat = (beatPos - beatIdx) * beat;  // seconds since beat
            // Kick: pitch-swept sine with fast decay.
            const double kf = 50.0 + 90.0 * std::exp(-inBeat * 40.0);
            static thread_local double kickPhase = 0;
            if (inBeat < 1.0 / s.sampleRate) kickPhase = 0;
            kickPhase += kTwoPi * kf / s.sampleRate;
            const double kick = std::sin(kickPhase) * std::exp(-inBeat * 9.0) * s.drums;
            // Off-beat hat: high-passed noise burst.
            const double offT = std::fmod(t + beat * 0.5, beat);
            const float n = noise(rng);
            hpState = 0.6f * (hpState + n - prevNoise);
            prevNoise = n;
            const double hat = hpState * std::exp(-offT * 60.0) * s.hats;
            // Harmony: one chord per bar.
            const auto& chord = s.chords[size_t(beatIdx / 4) % s.chords.size()];
            double pad = 0;
            for (int note : chord) {
                const double f = midiToHz(note);
                pad += std::sin(kTwoPi * f * t) + 0.3 * std::sin(kTwoPi * 2 * f * t);
            }
            pad *= s.pads / chord.size();
            // Bass: root on every off-beat 8th.
            const double f0 = midiToHz(chord[0] + s.bassRootOffset + 12);
            const double bassEnv = std::exp(-offT * 6.0);
            const double bass = std::sin(kTwoPi * f0 * t) * bassEnv * s.bass;
            l = kick + bass + pad * 0.9 + hat * 0.7;
            r = kick + bass + pad * 1.1 + hat * 1.3;
        }
        b->samples[2 * i] = float(l * 0.6);
        b->samples[2 * i + 1] = float(r * 0.6);
    }
    return b;
}

inline std::shared_ptr<AudioBuffer> makeSine(double freq, double seconds, double sampleRate, float amp = 0.5f) {
    auto b = std::make_shared<AudioBuffer>();
    b->sampleRate = sampleRate;
    b->frames = int64_t(seconds * sampleRate);
    b->samples.resize(size_t(b->frames) * 2);
    for (int64_t i = 0; i < b->frames; ++i) {
        const float v = float(amp * std::sin(kTwoPi * freq * double(i) / sampleRate));
        b->samples[2 * i] = v;
        b->samples[2 * i + 1] = v;
    }
    return b;
}

// Goertzel magnitude of a frequency in a mono signal (amplitude-normalised).
inline double toneLevel(const float* x, size_t n, size_t stride, double freq, double sampleRate) {
    const double w = kTwoPi * freq / sampleRate;
    const double c = 2 * std::cos(w);
    double s1 = 0, s2 = 0;
    for (size_t i = 0; i < n; ++i) {
        const double s0 = x[i * stride] + c * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    const double power = s1 * s1 + s2 * s2 - c * s1 * s2;
    return 2.0 * std::sqrt(std::max(0.0, power)) / double(n);
}

}  // namespace sbe::synth
