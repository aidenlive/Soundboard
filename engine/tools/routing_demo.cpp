// Soundboard routing prototype.
//
// Runs a scripted beginner session through the real engine, exactly as a device callback
// would (256-frame blocks), and writes what the crowd and the DJ would hear:
//
//   master.wav        — speakers (stereo)
//   headphones.wav    — DJ's headphones (stereo)
//   multichannel.wav  — 4-channel device view: ch1/2 master, ch3/4 cue (USB interface case)
//   split_mono.wav    — 2-channel splitter-cable view: L master (mono), R cue (mono)
//
// and verifies the property the whole product depends on: everything the DJ does in the
// headphones — library preview, pre-listening, syncing the next track — leaves the master
// bit-for-bit untouched.
//
// Usage: sbe_routing_demo [output_dir] [trackA.wav trackB.wav]
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "analysis.hpp"
#include "engine.hpp"
#include "synth.hpp"
#include "wav.hpp"

using namespace sbe;

namespace {

constexpr double kSR = 48000.0;
constexpr int kBlock = 256;

struct Render {
    std::vector<float> ch[4];
};

std::shared_ptr<AudioBuffer> loadOrSynth(const char* path, const synth::TrackSpec& spec) {
    if (path) {
        WavData w;
        std::string err;
        if (!readWav(path, w, &err)) { std::fprintf(stderr, "cannot read %s: %s\n", path, err.c_str()); std::exit(1); }
        return AudioBuffer::fromInterleaved(w.samples.data(), w.frames(), w.channels, w.sampleRate);
    }
    return synth::makeTrack(spec);
}

// The scripted session. `djActions` = false renders the same set with no headphone activity,
// which is the reference the master must match exactly up to the transition.
Render runSession(Topology topo, TrackRef a, TrackRef b, double seconds, bool djActions, double* transitionAt) {
    Engine e(kSR, kBlock, 2);
    OutputLayout layout;
    layout.topology = topo;
    if (topo == Topology::SplitMono) { layout.masterLeft = layout.masterRight = 0; layout.cueLeft = layout.cueRight = 1; }
    e.setOutputLayout(layout);
    e.loadTrack(0, a);
    e.loadTrack(1, b);
    e.setCrossfader(-1.0f);
    e.play(0);

    Render out;
    float buf[4][kBlock];
    float* ptr[4] = {buf[0], buf[1], buf[2], buf[3]};
    const int nch = topo == Topology::SplitMono ? 2 : 4;
    const double beat = 60.0 / a->grid.bpm;
    // Start the transition on a phrase boundary (bar 5 of track A).
    const double transitionTime = a->grid.firstBeatFrame / a->sampleRate + 16 * beat;
    if (transitionAt) *transitionAt = transitionTime;
    bool previewed = false, stoppedPreview = false, cued = false, transitioned = false, cueOff = false;

    for (double t = 0; t < seconds; t += kBlock / kSR) {
        if (djActions) {
            if (!previewed && t >= 1.0) {            // browse: preview B from its middle in headphones
                e.previewLoad(b, b->frames * 0.4);
                e.previewPlay();
                previewed = true;
            }
            if (!stoppedPreview && t >= 4.0) { e.previewStop(); stoppedPreview = true; }
            if (!cued && t >= 4.5) {                 // cue B, sync it, let it run in the headphones
                e.setCueEnabled(1, true);
                e.setCueMix(0.25f);                  // a little master in the cans to beatmatch by ear
                e.sync(1, true);
                e.play(1);
                cued = true;
            }
        }
        if (!transitioned && t >= transitionTime) {
            if (!djActions) { e.sync(1, true); e.play(1); }
            e.startTransition(0, 1, 16, TransitionStyle::BassSwap);
            transitioned = true;
        }
        if (djActions && !cueOff && t >= transitionTime + 16 * beat + 1.0) { e.setCueEnabled(1, false); cueOff = true; }
        e.render(ptr, nch, kBlock);
        for (int c = 0; c < nch; ++c) out.ch[c].insert(out.ch[c].end(), buf[c], buf[c] + kBlock);
    }
    return out;
}

void writeStereo(const std::string& path, const std::vector<float>& l, const std::vector<float>& r, int bits) {
    WavData w;
    w.channels = 2;
    w.sampleRate = kSR;
    w.samples.resize(l.size() * 2);
    for (size_t i = 0; i < l.size(); ++i) { w.samples[2 * i] = l[i]; w.samples[2 * i + 1] = r[i]; }
    writeWav(path, w, bits);
}

float maxAbs(const std::vector<float>& v, size_t from, size_t to) {
    float m = 0;
    for (size_t i = from; i < std::min(to, v.size()); ++i) m = std::max(m, std::fabs(v[i]));
    return m;
}

}  // namespace

int main(int argc, char** argv) {
    const std::string dir = argc > 1 ? argv[1] : ".";
    const char* pathA = argc > 3 ? argv[2] : nullptr;
    const char* pathB = argc > 3 ? argv[3] : nullptr;

    synth::TrackSpec sa; sa.bpm = 124; sa.seconds = 45; sa.sampleRate = 44100; sa.seed = 11;
    synth::TrackSpec sb = sa; sb.bpm = 126; sb.seed = 23; sb.firstBeatSeconds = 0.4;
    sb.chords = {{60, 64, 67}, {57, 60, 64}, {53, 57, 60}, {55, 59, 62}};  // C major: I-vi-IV-V
    auto a = loadOrSynth(pathA, sa);
    auto b = loadOrSynth(pathB, sb);

    std::printf("Soundboard routing prototype\n============================\n\nAnalysis\n");
    for (auto* t : {&a, &b}) {
        const Analysis an = analyzeTrack(**t);
        (*t)->grid = an.grid;
        (*t)->autoGainDb = an.autoGainDb;
        std::printf("  %s: %.2f BPM (confidence %.2f), first beat %.1f ms, key %s / %s, %.1f LUFS -> auto-gain %+.1f dB\n",
                    t == &a ? "Track A" : "Track B", an.grid.bpm, an.tempoConfidence,
                    an.grid.firstBeatFrame / (*t)->sampleRate * 1000.0, an.key.name.c_str(), an.key.camelot.c_str(),
                    an.loudnessLufs, an.autoGainDb);
    }
    const Analysis ka = analyzeTrack(*a), kb = analyzeTrack(*b);
    std::printf("  Harmonic match: %s\n\n", keysCompatible(ka.key.index, kb.key.index) ? "compatible (Camelot neighbours)" : "clash");

    const double seconds = 34.0;
    double transitionAt = 0;
    const Render live = runSession(Topology::MultiChannel, a, b, seconds, true, &transitionAt);
    const Render ref = runSession(Topology::MultiChannel, a, b, seconds, false, nullptr);
    const Render split = runSession(Topology::SplitMono, a, b, seconds, true, nullptr);

    // 1. Isolation: before the transition, the master must be identical with or without
    //    any headphone activity.
    const size_t until = size_t(transitionAt * kSR);
    float diff = 0;
    for (int c = 0; c < 2; ++c)
        for (size_t i = 0; i < until; ++i) diff = std::max(diff, std::fabs(live.ch[c][i] - ref.ch[c][i]));
    const float cuePeakBeforeTransition = maxAbs(live.ch[2], size_t(1.0 * kSR), until);

    // 2. Click / clip safety on the master.
    float worstStep = 0, peak = 0;
    for (int c = 0; c < 2; ++c) {
        for (size_t i = 1; i < live.ch[c].size(); ++i) worstStep = std::max(worstStep, std::fabs(live.ch[c][i] - live.ch[c][i - 1]));
        peak = std::max(peak, maxAbs(live.ch[c], 0, live.ch[c].size()));
    }

    std::printf("Session (%.0f s, %d-frame callbacks, 4-channel device)\n", seconds, kBlock);
    std::printf("  0.0 s  Track A playing on master\n");
    std::printf("  1.0 s  Library preview of Track B in headphones\n");
    std::printf("  4.5 s  Track B cued + synced in headphones (cue/master blend 25%%)\n");
    std::printf("  %.1f s  16-beat bass-swap transition A -> B on the phrase\n\n", transitionAt);
    std::printf("Verification\n");
    std::printf("  Master difference caused by headphone activity: %.9f  %s\n", diff, diff == 0.0f ? "(bit-identical)" : "");
    std::printf("  Headphone bus active meanwhile: peak %.3f\n", cuePeakBeforeTransition);
    std::printf("  Master peak %.4f (ceiling %.4f)  %s\n", peak, dbToGain(-0.3f), peak <= dbToGain(-0.3f) + 1e-6f ? "no clipping" : "CLIPPED");
    std::printf("  Largest sample-to-sample step on master: %.3f\n\n", worstStep);

    writeStereo(dir + "/master.wav", live.ch[0], live.ch[1], 16);
    writeStereo(dir + "/headphones.wav", live.ch[2], live.ch[3], 16);
    writeStereo(dir + "/split_mono.wav", split.ch[0], split.ch[1], 16);
    WavData mc;
    mc.channels = 4;
    mc.sampleRate = kSR;
    mc.samples.resize(live.ch[0].size() * 4);
    for (size_t i = 0; i < live.ch[0].size(); ++i)
        for (int c = 0; c < 4; ++c) mc.samples[4 * i + c] = live.ch[c][i];
    writeWav(dir + "/multichannel.wav", mc, 24);
    std::printf("Wrote master.wav, headphones.wav, split_mono.wav, multichannel.wav to %s\n", dir.c_str());

    const bool ok = diff == 0.0f && cuePeakBeforeTransition > 0.05f && peak <= dbToGain(-0.3f) + 1e-6f;
    std::printf("\nRESULT: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
