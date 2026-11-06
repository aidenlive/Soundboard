// Soundboard Engine test suite. Zero dependencies: `ctest` or run the binary directly.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "analysis.hpp"
#include "dsp.hpp"
#include "engine.hpp"
#include "fifo.hpp"
#include "soundboard/sbe.h"
#include "synth.hpp"
#include "wav.hpp"

using namespace sbe;

// ---- micro test framework ----------------------------------------------------------------
struct TestCase { const char* name; std::function<void()> fn; };
static std::vector<TestCase>& registry() { static std::vector<TestCase> r; return r; }
static int g_failures = 0;
struct Registrar { Registrar(const char* n, std::function<void()> f) { registry().push_back({n, std::move(f)}); } };
#define TEST(name) static void name(); static Registrar reg_##name(#name, name); static void name()
#define CHECK(cond) do { if (!(cond)) { std::printf("    FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); ++g_failures; } } while (0)
#define CHECK_NEAR(a, b, tol) do { const double _a = (a), _b = (b); if (std::fabs(_a - _b) > (tol)) { \
    std::printf("    FAIL %s:%d  %s = %.6f, expected %.6f ± %.6f\n", __FILE__, __LINE__, #a, _a, _b, double(tol)); ++g_failures; } } while (0)
#define INFO(...) std::printf("    " __VA_ARGS__)

// ---- helpers -----------------------------------------------------------------------------
constexpr double kSR = 48000.0;
constexpr int kBlock = 256;

struct Capture {
    int channels;
    std::vector<std::vector<float>> ch;
    explicit Capture(int n) : channels(n), ch(size_t(n)) {}
    size_t size() const { return ch[0].size(); }
};

// Renders `seconds` of audio in device-sized blocks, appending to the capture.
static void run(Engine& e, Capture& cap, double seconds, int block = kBlock) {
    const int total = int(seconds * e.sampleRate());
    std::vector<std::vector<float>> buf(size_t(cap.channels), std::vector<float>(size_t(block)));
    std::vector<float*> ptrs(size_t(cap.channels));
    for (int done = 0; done < total; done += block) {
        const int n = std::min(block, total - done);
        for (int c = 0; c < cap.channels; ++c) ptrs[c] = buf[c].data();
        e.render(ptrs.data(), cap.channels, n);
        for (int c = 0; c < cap.channels; ++c) cap.ch[c].insert(cap.ch[c].end(), buf[c].begin(), buf[c].begin() + n);
    }
}

static double level(const std::vector<float>& x, size_t from, size_t to, double freq) {
    to = std::min(to, x.size());
    if (to <= from) return 0;
    return synth::toneLevel(x.data() + from, to - from, 1, freq, kSR);
}

static float maxStep(const std::vector<float>& x, size_t from = 0, size_t to = SIZE_MAX) {
    float m = 0;
    to = std::min(to, x.size());
    for (size_t i = from + 1; i < to; ++i) m = std::max(m, std::fabs(x[i] - x[i - 1]));
    return m;
}

static float peak(const std::vector<float>& x, size_t from = 0, size_t to = SIZE_MAX) {
    float m = 0;
    to = std::min(to, x.size());
    for (size_t i = from; i < to; ++i) m = std::max(m, std::fabs(x[i]));
    return m;
}

static double db(double x) { return 20.0 * std::log10(std::max(x, 1e-12)); }

static TrackRef withGrid(std::shared_ptr<AudioBuffer> b, double bpm, double first) {
    b->grid = BeatGrid{bpm, first};
    return b;
}

// ---- DSP ---------------------------------------------------------------------------------
TEST(isolator_eq_is_flat_at_unity_and_kills_bands) {
    for (double f : {40.0, 120.0, 250.0, 800.0, 2500.0, 6000.0, 15000.0}) {
        IsolatorEq eq;
        eq.prepare(kSR);
        const int n = int(kSR);
        std::vector<float> l(n), r(n);
        for (int i = 0; i < n; ++i) l[i] = r[i] = float(0.5 * std::sin(2 * kPi * f * i / kSR));
        eq.process(l.data(), r.data(), n);
        const double gain = synth::toneLevel(l.data() + n / 2, n / 2, 1, f, kSR) / 0.5;
        CHECK_NEAR(db(gain), 0.0, 0.05);
    }
    // Low kill at 50 Hz, high kill at 8 kHz.
    struct Case { int band; double f; };
    for (Case c : {Case{0, 50.0}, Case{2, 8000.0}, Case{1, 900.0}}) {
        IsolatorEq eq;
        eq.prepare(kSR);
        eq.snapBandDb(c.band, -96.0f);
        const int n = int(kSR);
        std::vector<float> l(n), r(n);
        for (int i = 0; i < n; ++i) l[i] = r[i] = float(0.5 * std::sin(2 * kPi * c.f * i / kSR));
        eq.process(l.data(), r.data(), n);
        const double att = db(synth::toneLevel(l.data() + n / 2, n / 2, 1, c.f, kSR) / 0.5);
        INFO("band %d kill @ %.0f Hz: %.1f dB\n", c.band, c.f, att);
        CHECK(att < (c.band == 1 ? -25.0 : -40.0));
    }
}

TEST(limiter_never_exceeds_ceiling) {
    LookaheadLimiter lim;
    lim.prepare(kSR);
    lim.setCeilingDb(-1.0f);
    const float ceiling = dbToGain(-1.0f);
    std::mt19937 rng(7);
    std::uniform_real_distribution<float> u(-1, 1);
    const int n = int(kSR * 2);
    std::vector<float> l(n), r(n);
    for (int i = 0; i < n; ++i) {
        const float burst = (i / 4800) % 3 == 0 ? 4.0f : 0.3f;  // +12 dB bursts
        l[i] = burst * float(std::sin(2 * kPi * 60 * i / kSR)) + 0.2f * u(rng);
        r[i] = (i % 9973 == 0) ? 8.0f : l[i] * 0.8f;              // isolated spikes
    }
    lim.process(l.data(), r.data(), n);
    CHECK(peak(l) <= ceiling + 1e-6f);
    CHECK(peak(r) <= ceiling + 1e-6f);
    INFO("limiter latency %d samples, peak %.4f (ceiling %.4f)\n", lim.latencySamples(), std::max(peak(l), peak(r)), ceiling);
}

TEST(drift_fifo_absorbs_clock_mismatch) {
    // Two devices with independent crystals and different buffer sizes (256 vs 480 frames).
    for (double ppm : {-300.0, 120.0, 500.0}) {
        DriftCompensatedFifo fifo;
        fifo.prepare(1024, 48000, kSR);
        const double consRate = kSR * (1.0 + ppm * 1e-6);
        const double expected = 1.0 / (1.0 + ppm * 1e-6);
        double prodClock = 0, consClock = 0, phase = 0, ratioSum = 0, worstDev = 0;
        long ratioCount = 0;
        std::vector<float> l(256), r(256), ol(480), orr(480), out;
        while (consClock < 180.0) {
            if (prodClock <= consClock) {
                for (int i = 0; i < 256; ++i) { l[i] = r[i] = float(std::sin(phase)); phase += 2 * kPi * 440 / kSR; }
                fifo.push(l.data(), r.data(), 256);
                prodClock += 256 / kSR;
            } else {
                fifo.pull(ol.data(), orr.data(), 480);
                consClock += 480 / consRate;
                if (consClock > 2.0 && consClock < 12.0) out.insert(out.end(), ol.begin(), ol.end());
                if (consClock > 90.0) {
                    ratioSum += fifo.ratio();
                    ++ratioCount;
                    worstDev = std::max(worstDev, std::fabs(fifo.ratio() - expected));
                }
            }
        }
        const double mean = ratioSum / double(ratioCount);
        INFO("drift %+.0f ppm: mean ratio %.6f (ideal %.6f), worst deviation %.1f ppm, underruns %u\n", ppm, mean,
             expected, worstDev * 1e6, fifo.underruns());
        CHECK(fifo.underruns() == 0);
        CHECK_NEAR(mean, expected, 20e-6);
        CHECK(worstDev < 100e-6);  // < 0.2 cent of pitch modulation on the cue feed
        CHECK(maxStep(out) < 2 * kPi * 440 / kSR * 1.2);  // continuous: no jumps
    }
}

// ---- Deck transport ----------------------------------------------------------------------
TEST(transport_is_click_free) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::MasterOnly});
    auto sine = synth::makeSine(1000.0, 20.0, kSR, 0.9f);
    e.loadTrack(0, withGrid(sine, 120.0, 0.0));
    e.setCrossfader(-1.0f);
    e.setAutoGain(false);
    Capture cap(2);
    run(e, cap, 0.05);
    e.play(0);       run(e, cap, 0.5);
    e.pause(0);      run(e, cap, 0.2);
    e.play(0);       run(e, cap, 0.3);
    e.seek(0, kSR * 7.3123);  run(e, cap, 0.3);   // arbitrary jump: phase discontinuity
    e.setBeatLoop(0, 0.37);   run(e, cap, 1.0);   // loop wraps at a non-period boundary
    e.exitLoop(0);
    e.beatJump(0, 3.3);       run(e, cap, 0.3);
    e.setHotCue(0, 0, kSR * 2.71);
    e.triggerHotCue(0, 0);    run(e, cap, 0.3);
    e.cuePress(0);            run(e, cap, 0.2);   // CDJ cue: jump to cue + stop
    const float natural = float(2 * kPi * 1000 / kSR * 0.9);  // max slope of the sine itself
    const float worst = maxStep(cap.ch[0]);
    INFO("max sample step %.4f (natural %.4f, hard cut would be up to 1.8)\n", worst, natural);
    CHECK(worst < natural * 1.6f);
}

TEST(cdj_cue_semantics) {
    Engine e(kSR, kBlock);
    auto t = withGrid(synth::makeSine(200, 30, kSR), 120.0, 0.0);
    e.loadTrack(0, t);
    Capture cap(2);
    e.seek(0, kSR * 4.1); run(e, cap, 0.05);
    e.cuePress(0); run(e, cap, 0.05);                // paused elsewhere: set cue (quantised)
    CHECK_NEAR(e.deckStatus(0).cuePoint, kSR * 4.0, 1.0);
    e.cuePress(0); run(e, cap, 0.5);                 // held at cue: preview plays
    CHECK(e.deckStatus(0).playing);
    e.cueRelease(0); run(e, cap, 0.05);              // release: back to cue, stopped
    CHECK(!e.deckStatus(0).playing);
    CHECK_NEAR(e.deckStatus(0).position, kSR * 4.0, 1.0);
}

TEST(saved_loop_restores_inactive_then_reloops) {
    Engine e(kSR, kBlock);
    e.loadTrack(0, withGrid(synth::makeSine(200, 30, kSR), 120.0, 0.0));
    Capture cap(2);
    e.setLoop(0, kSR * 2.0, kSR * 3.0, false); run(e, cap, 0.02);
    CHECK(!e.deckStatus(0).loopActive);
    CHECK_NEAR(e.deckStatus(0).loopIn, kSR * 2.0, 0.5);
    CHECK_NEAR(e.deckStatus(0).loopOut, kSR * 3.0, 0.5);
    e.seek(0, kSR * 2.5); e.reloop(0); e.play(0); run(e, cap, 1.5);   // longer than the loop
    CHECK(e.deckStatus(0).loopActive);
    const double pos = e.deckStatus(0).position;
    CHECK(pos >= kSR * 2.0 && pos < kSR * 3.0);
}

// ---- Routing: the core problem -----------------------------------------------------------
TEST(cue_never_leaks_into_master_multichannel) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::MultiChannel, 0, 1, 2, 3});
    e.setAutoGain(false);
    e.loadTrack(0, withGrid(synth::makeSine(300.0, 10, kSR), 120, 0));  // live on master
    e.loadTrack(1, withGrid(synth::makeSine(700.0, 10, kSR), 120, 0));  // being cued
    e.setCrossfader(-1.0f);
    e.setFader(1, 0.0f);
    e.setCueEnabled(1, true);
    e.play(0); e.play(1);
    Capture cap(4);
    run(e, cap, 2.0);
    const size_t a = size_t(kSR), b = size_t(2 * kSR);
    const double masterA = level(cap.ch[0], a, b, 300), masterB = level(cap.ch[0], a, b, 700);
    const double cueA = level(cap.ch[2], a, b, 300), cueB = level(cap.ch[2], a, b, 700);
    INFO("master: A %.1f dB, B %.1f dB | cue: A %.1f dB, B %.1f dB\n", db(masterA), db(masterB), db(cueA), db(cueB));
    CHECK(db(masterA) > -10);
    CHECK(db(masterB) < -100);  // cued track inaudible to the crowd
    CHECK(db(cueB) > -10);
    CHECK(db(cueA) < -100);     // headphones hear only what is cued (cue mix = 0)

    // Blend master into headphones.
    e.setCueMix(0.5f);
    Capture cap2(4);
    run(e, cap2, 1.0);
    CHECK(db(level(cap2.ch[2], size_t(kSR / 2), size_t(kSR), 300)) > -20);
}

TEST(split_mono_topology_and_preview_isolation) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::SplitMono, 0, 0, 1, 1});
    e.setAutoGain(false);
    e.loadTrack(0, withGrid(synth::makeSine(330.0, 10, kSR), 120, 0));
    e.play(0);
    e.setCrossfader(-1.0f);
    // Library preview of a different track: headphones only.
    e.previewLoad(synth::makeSine(880.0, 10, kSR), 0.0);
    e.previewPlay();
    Capture cap(2);
    run(e, cap, 1.5);
    const size_t a = size_t(kSR / 2), b = size_t(1.5 * kSR);
    INFO("L(master) 880 Hz: %.1f dB | R(cue) 880 Hz: %.1f dB, 330 Hz: %.1f dB\n",
         db(level(cap.ch[0], a, b, 880)), db(level(cap.ch[1], a, b, 880)), db(level(cap.ch[1], a, b, 330)));
    CHECK(db(level(cap.ch[0], a, b, 330)) > -12);
    CHECK(db(level(cap.ch[0], a, b, 880)) < -100);  // preview never reaches the crowd
    CHECK(db(level(cap.ch[1], a, b, 880)) > -12);
    CHECK(db(level(cap.ch[1], a, b, 330)) < -100);
}

TEST(master_only_topology_disables_cue_bus) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::MasterOnly});
    e.loadTrack(0, withGrid(synth::makeSine(500.0, 5, kSR), 120, 0));
    e.setCueEnabled(0, true);
    e.setFader(0, 0.0f);
    e.play(0);
    Capture cap(2);
    run(e, cap, 0.5);
    CHECK(!e.status().cueAvailable);
    CHECK(peak(cap.ch[0], size_t(kSR / 4)) < 1e-6f);  // cue does not fall back onto master
}

TEST(separate_cue_device_with_drift) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::SeparateCueDevice, 0, 1});
    e.setAutoGain(false);
    e.loadTrack(0, withGrid(synth::makeSine(250.0, 30, kSR), 120, 0));
    e.loadTrack(1, withGrid(synth::makeSine(1250.0, 30, kSR), 120, 0));
    e.setFader(1, 0.0f);
    e.setCueEnabled(1, true);
    e.setCrossfader(-1.0f);
    e.play(0); e.play(1);
    // Master device at 48 kHz, headphone device 200 ppm fast with a different block size.
    std::vector<float> ml(256), mr(256), cl(480), cr(480), cueOut;
    double tm = 0, tc = 0;
    const double cueRate = kSR * (1 + 200e-6);
    while (tc < 20.0) {
        if (tm <= tc) { float* o[2] = {ml.data(), mr.data()}; e.render(o, 2, 256); tm += 256 / kSR; }
        else { float* o[2] = {cl.data(), cr.data()}; e.renderCue(o, 2, 480); tc += 480 / cueRate; if (tc > 2) cueOut.insert(cueOut.end(), cl.begin(), cl.end()); }
    }
    const EngineStatus s = e.status();
    // Average over short windows: the resampling ratio wanders by a few ppm, which a single
    // 18-second Goertzel window (0.05 Hz bandwidth) would misread as attenuation.
    auto chunked = [&](double f) {
        const size_t w = size_t(cueRate / 2);
        double sum = 0; int n = 0;
        for (size_t at = 0; at + w <= cueOut.size(); at += w, ++n) sum += synth::toneLevel(cueOut.data() + at, w, 1, f, cueRate);
        return n ? sum / n : 0.0;
    };
    const double cueLevel = db(chunked(1250)), leak = db(chunked(250));
    INFO("cue device: ratio %.6f, underruns %u, cued tone %.1f dB, master tone %.1f dB\n", s.cueDriftRatio,
         s.cueUnderruns, cueLevel, leak);
    CHECK(s.cueUnderruns == 0);
    CHECK(cueLevel > -7.0);
    CHECK(leak < -60.0);  // window sidelobes of the 1250 Hz tone sit near -80 dB; real leakage would be ~-6 dB
    CHECK(maxStep(cueOut) < float(2 * kPi * 1250 / kSR) * 1.3f);
}

TEST(latency_compensation_delays_cue_bus) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::MultiChannel, 0, 1, 2, 3});
    e.setLatencyCompensation(0, 9600);  // 200 ms, e.g. master on Bluetooth
    auto click = std::make_shared<AudioBuffer>();
    click->sampleRate = kSR; click->frames = int64_t(kSR * 2);
    click->samples.assign(size_t(click->frames) * 2, 0.0f);
    for (int i = 4800; i < 4810; ++i) click->samples[2 * i] = click->samples[2 * i + 1] = 0.8f;
    e.setAutoGain(false);
    e.loadTrack(0, click);
    e.setCueEnabled(0, true);
    e.setCueMix(0.0f);
    e.setCrossfader(-1);
    e.play(0);
    Capture cap(4);
    run(e, cap, 1.0);
    auto firstAbove = [](const std::vector<float>& v) { for (size_t i = 0; i < v.size(); ++i) if (std::fabs(v[i]) > 0.1f) return long(i); return -1L; };
    const long m = firstAbove(cap.ch[0]), c = firstAbove(cap.ch[2]);
    INFO("master click @ %ld, cue click @ %ld (Δ %ld frames)\n", m, c, c - m);
    CHECK(m > 0 && c > 0);
    CHECK_NEAR(double(c - m), 9600.0, 2.0);
}

// ---- Mixer -------------------------------------------------------------------------------
TEST(crossfader_constant_power) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::MasterOnly});
    e.setAutoGain(false);
    e.loadTrack(0, withGrid(synth::makeSine(300.0, 5, kSR, 0.25f), 120, 0));
    e.loadTrack(1, withGrid(synth::makeSine(900.0, 5, kSR, 0.25f), 120, 0));
    e.play(0); e.play(1);
    e.setCrossfader(0.0f);
    Capture cap(2);
    run(e, cap, 0.5);
    const double a = level(cap.ch[0], size_t(kSR / 4), size_t(kSR / 2), 300) / 0.25;
    const double b = level(cap.ch[0], size_t(kSR / 4), size_t(kSR / 2), 900) / 0.25;
    CHECK_NEAR(a * a + b * b, 1.0, 0.02);
}

// Regression: a one-pole smoother stalled a few ulps short of -1, leaking the parked side of
// the crossfader into the master at about -140 dB. Parked must mean bit-exact silence.
TEST(parked_crossfader_side_is_exactly_silent) {
    auto render = [](bool withB) {
        Engine e(kSR, kBlock);
        e.setOutputLayout({Topology::MasterOnly});
        e.loadTrack(0, withGrid(synth::makeSine(300.0, 5, kSR), 120, 0));
        e.loadTrack(1, withGrid(synth::makeSine(700.0, 5, kSR), 120, 0));
        e.setCrossfader(-1.0f);
        e.play(0);
        if (withB) e.play(1);
        Capture cap(2);
        run(e, cap, 2.0);
        return cap.ch[0];
    };
    const auto a = render(false), ab = render(true);
    bool identical = a.size() == ab.size();
    // Skip the initial 6 ms crossfader glide from centre to A.
    for (size_t i = size_t(kSR / 2); identical && i < a.size(); ++i) identical = a[i] == ab[i];
    CHECK(identical);
}

TEST(master_output_never_clips) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::MasterOnly});
    synth::TrackSpec s; s.sampleRate = kSR; s.seconds = 6;
    e.loadTrack(0, synth::makeTrack(s));
    s.bpm = 124; s.seed = 3;
    e.loadTrack(1, synth::makeTrack(s));
    e.setCrossfader(0.0f);
    e.setTrim(0, 12.0f); e.setTrim(1, 12.0f);
    e.setEq(0, EqBand::Low, 6.0f);
    e.setMasterGain(6.0f);
    e.play(0); e.play(1);
    Capture cap(2);
    run(e, cap, 5.0);
    const float ceiling = dbToGain(-0.3f);
    INFO("peak %.4f, ceiling %.4f, gain reduction %.1f dB\n", std::max(peak(cap.ch[0]), peak(cap.ch[1])), ceiling, e.status().limiterReductionDb);
    CHECK(peak(cap.ch[0]) <= ceiling + 1e-6f);
    CHECK(peak(cap.ch[1]) <= ceiling + 1e-6f);
}

TEST(recording_tap_matches_master) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::MasterOnly});
    e.loadTrack(0, withGrid(synth::makeSine(440, 5, kSR), 120, 0));
    e.play(0);
    e.setCrossfader(-1);
    e.setRecording(true);
    Capture cap(2);
    run(e, cap, 1.0);
    std::vector<float> rec(size_t(kSR * 2) * 2);
    const size_t n = e.readRecording(rec.data(), size_t(kSR * 2));
    CHECK(n == cap.size());
    double maxDiff = 0;
    for (size_t i = 0; i < std::min(n, cap.size()); ++i) maxDiff = std::max(maxDiff, double(std::fabs(rec[2 * i] - cap.ch[0][i])));
    CHECK(maxDiff < 1e-7);
}

// ---- Sync & transitions ------------------------------------------------------------------
TEST(beat_sync_matches_tempo_and_phase) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::MultiChannel, 0, 1, 2, 3});
    synth::TrackSpec a; a.sampleRate = 44100; a.bpm = 124; a.seconds = 60; a.firstBeatSeconds = 0.25;
    synth::TrackSpec b = a; b.bpm = 128.5; b.firstBeatSeconds = 0.61; b.seed = 9;
    auto ta = synth::makeTrack(a); ta->grid = {124, 0.25 * 44100};
    auto tb = synth::makeTrack(b); tb->grid = {128.5, 0.61 * 44100};
    e.loadTrack(0, ta);
    e.loadTrack(1, tb);
    e.play(0);
    Capture cap(4);
    run(e, cap, 3.3);
    e.seek(1, 44100 * 10.37);
    e.sync(1, true);
    e.play(1);
    run(e, cap, 0.2);
    // Nudge the leader's tempo: the lock must follow.
    e.setTempo(0, 1.02);
    run(e, cap, 8.0);
    const DeckStatus s0 = e.deckStatus(0), s1 = e.deckStatus(1);
    const double phaseErr = std::fabs(std::remainder(s0.beat - s1.beat, 1.0));
    INFO("bpm A %.3f B %.3f, phase error %.4f beats (%.2f ms)\n", s0.effectiveBpm, s1.effectiveBpm, phaseErr, phaseErr * 60000.0 / s0.effectiveBpm);
    CHECK_NEAR(s1.effectiveBpm, s0.effectiveBpm, 1e-6);
    CHECK(phaseErr < 0.004);  // < 2 ms at 126 BPM
    CHECK(s1.syncLocked);
}

TEST(bass_swap_transition_completes) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::MasterOnly});
    synth::TrackSpec a; a.sampleRate = kSR; a.seconds = 40;
    auto ta = synth::makeTrack(a); ta->grid = {124, 0.25 * kSR};
    synth::TrackSpec b = a; b.bpm = 126; b.seed = 4;
    auto tb = synth::makeTrack(b); tb->grid = {126, 0.25 * kSR};
    e.loadTrack(0, ta);
    e.loadTrack(1, tb);
    e.setCrossfader(-1.0f);
    e.play(0);
    Capture cap(2);
    run(e, cap, 1.0);
    e.startTransition(0, 1, 16, TransitionStyle::BassSwap);
    run(e, cap, 0.1);
    CHECK(e.status().transitionProgress >= 0.0f);
    CHECK(e.deckStatus(1).playing);
    run(e, cap, 16 * 60.0 / 124 + 0.5);
    const DeckStatus s0 = e.deckStatus(0), s1 = e.deckStatus(1);
    CHECK(e.status().transitionProgress < 0.0f);
    CHECK(!s0.playing);
    CHECK(s1.playing);
    CHECK_NEAR(e.status().crossfader, 1.0, 1e-3);
    CHECK(maxStep(cap.ch[0]) < 0.5f);
}

TEST(transition_waits_for_phrase_boundary) {
    Engine e(kSR, kBlock);
    e.setOutputLayout({Topology::MasterOnly});
    synth::TrackSpec a; a.sampleRate = kSR; a.seconds = 60; a.firstBeatSeconds = 0;
    auto ta = synth::makeTrack(a); ta->grid = {120, 0};
    synth::TrackSpec b = a; b.seed = 5;
    auto tb = synth::makeTrack(b); tb->grid = {120, 0};
    e.loadTrack(0, ta);
    e.loadTrack(1, tb);
    e.setCrossfader(-1.0f);
    e.play(0);
    Capture cap(2);
    run(e, cap, 3.0);                       // deck A at beat ~6
    e.startTransition(0, 1, 8, TransitionStyle::Blend, 16);
    run(e, cap, 0.1);
    const EngineStatus waiting = e.status();
    INFO("waiting: starts in %.2f beats, progress %.2f, deck B playing %d\n", waiting.transitionStartsInBeats,
         waiting.transitionProgress, int(e.deckStatus(1).playing));
    CHECK(waiting.transitionStartsInBeats > 9.0f && waiting.transitionStartsInBeats < 10.5f);  // phrase at beat 16
    CHECK(e.deckStatus(1).playing);                     // incoming deck already running, inaudible
    CHECK_NEAR(e.status().crossfader, -1.0, 1e-3);      // nothing has moved yet
    run(e, cap, 5.2);                                   // past beat 16 (t = 8 s) and into the blend
    const EngineStatus blending = e.status();
    CHECK(blending.transitionStartsInBeats < 0.0f);
    CHECK(blending.transitionProgress > 0.0f);
    const double beatAtStart = e.deckStatus(0).beat - blending.transitionProgress * 8;
    INFO("blend began at deck A beat %.2f\n", beatAtStart);
    CHECK_NEAR(beatAtStart, 16.0, 0.3);
}

// ---- Analysis ----------------------------------------------------------------------------
TEST(bpm_and_grid_detection) {
    struct Case { double bpm, first, expected; };
    for (Case c : {Case{120.0, 0.25, 120.0}, Case{124.0, 0.1, 124.0}, Case{128.0, 0.37, 128.0},
                   Case{93.5, 0.2, 93.5}, Case{140.0, 0.05, 140.0}, Case{174.0, 0.3, 87.0}}) {
        synth::TrackSpec s; s.bpm = c.bpm; s.firstBeatSeconds = c.first; s.seconds = 45; s.seed = uint32_t(c.bpm);
        auto t = synth::makeTrack(s);
        double conf = 0;
        const BeatGrid g = detectBeatGrid(t->samples.data(), t->frames, t->sampleRate, {}, &conf);
        // Grid phase error relative to the true kicks (in ms, modulo the beat).
        const double beatLen = 60.0 / c.bpm * s.sampleRate;  // true beat (folded grids hit every 2nd)
        const double trueFirst = c.first * s.sampleRate;
        const double phaseErr = std::remainder(g.firstBeatFrame - trueFirst, beatLen) / s.sampleRate * 1000.0;
        INFO("%.1f BPM -> %.3f (conf %.2f), grid offset %+.1f ms\n", c.bpm, g.bpm, conf, phaseErr);
        CHECK_NEAR(g.bpm, c.expected, 0.02);
        CHECK(std::fabs(phaseErr) < 8.0);
    }
}

TEST(key_detection) {
    struct Case { std::vector<std::vector<int>> chords; int expected; const char* label; };
    std::vector<Case> cases = {
        {{{60, 64, 67}, {65, 69, 72}, {67, 71, 74}, {60, 64, 67}}, 0, "C major I-IV-V-I"},
        {{{57, 60, 64}, {62, 65, 69}, {64, 68, 71}, {57, 60, 64}}, 12 + 9, "A minor i-iv-V-i"},
        {{{54, 57, 61}, {59, 62, 66}, {61, 65, 68}, {54, 57, 61}}, 12 + 6, "F# minor i-iv-V-i"},
        {{{55, 59, 62}, {60, 64, 67}, {62, 66, 69}, {55, 59, 62}}, 7, "G major I-IV-V-I"},
    };
    for (const auto& c : cases) {
        synth::TrackSpec s; s.chords = c.chords; s.seconds = 30; s.pads = 0.6f; s.bass = 0.4f;
        auto t = synth::makeTrack(s);
        const KeyResult k = detectKey(t->samples.data(), t->frames, t->sampleRate);
        INFO("%-22s -> %s (%s), margin %.3f\n", c.label, k.name.c_str(), k.camelot.c_str(), k.confidence);
        CHECK(k.index == c.expected);
    }
    CHECK(camelotForKey(0) == "8B");
    CHECK(camelotForKey(21) == "8A");
    CHECK(camelotForKey(7) == "9B");
    CHECK(keysCompatible(0, 7) && keysCompatible(0, 21) && !keysCompatible(0, 6));
}

TEST(loudness_bs1770) {
    auto s = synth::makeSine(1000.0, 10.0, 48000.0, dbToGain(-20.0f));
    const double l = integratedLoudness(s->samples.data(), s->frames, s->sampleRate);
    INFO("1 kHz stereo sine at -20 dBFS -> %.2f LUFS (reference -20.0)\n", l);
    CHECK_NEAR(l, -20.0, 0.2);
}

TEST(waveform_bands) {
    auto low = synth::makeSine(60.0, 1.0, kSR);
    auto high = synth::makeSine(8000.0, 1.0, kSR);
    const auto wl = computeWaveform(low->samples.data(), low->frames, kSR, 480);
    const auto wh = computeWaveform(high->samples.data(), high->frames, kSR, 480);
    CHECK(wl.size() == 100);
    CHECK(wl[50].low > 5 * wl[50].high);
    CHECK(wh[50].high > 5 * wh[50].low);
}

// ---- Threading / C API -------------------------------------------------------------------
TEST(concurrent_control_and_audio_threads) {
    sbe_engine* e = sbe_engine_create(kSR, kBlock, 2);
    sbe_engine_set_output_layout(e, SBE_TOPOLOGY_MULTICHANNEL, 0, 1, 2, 3);
    auto src = synth::makeSine(220.0, 3.0, kSR);
    std::atomic<bool> stop{false};
    std::thread audio([&] {
        std::vector<float> b0(kBlock), b1(kBlock), b2(kBlock), b3(kBlock);
        float* o[4] = {b0.data(), b1.data(), b2.data(), b3.data()};
        while (!stop) sbe_engine_render(e, o, 4, kBlock);
    });
    std::mt19937 rng(1);
    for (int i = 0; i < 400; ++i) {
        sbe_track* t = sbe_track_create(src->samples.data(), src->frames, 2, kSR);
        sbe_track_set_grid(t, 120, 0);
        const int d = int(rng() % 2);
        sbe_deck_load(e, d, t);
        sbe_track_release(t);  // engine retains its own reference
        sbe_deck_play(e, d);
        sbe_channel_set_eq(e, d, SBE_EQ_LOW, float(int(rng() % 12)) - 6.0f);
        sbe_deck_beat_loop(e, d, 0.5);
        sbe_mixer_set_crossfader(e, float(rng() % 200) / 100.0f - 1.0f);
        sbe_engine_collect_garbage(e);
        if (i % 50 == 0) std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    stop = true;
    audio.join();
    sbe_engine_collect_garbage(e);
    sbe_deck_status st;
    sbe_deck_get_status(e, 0, &st);
    CHECK(st.loaded == 1);
    sbe_engine_destroy(e);
}

TEST(c_api_analysis_roundtrip) {
    synth::TrackSpec s; s.bpm = 126; s.seconds = 30;
    auto t = synth::makeTrack(s);
    sbe_track* tr = sbe_track_create(t->samples.data(), t->frames, 2, t->sampleRate);
    sbe_track_analysis a;
    sbe_track_analyze(tr, 0, -10.0, &a);
    INFO("C API: %.2f BPM, key %s (%s), %.1f LUFS, auto-gain %+.1f dB\n", a.bpm, a.key_name, a.camelot, a.loudness_lufs, a.auto_gain_db);
    CHECK_NEAR(a.bpm, 126.0, 0.02);
    CHECK(a.key_index == 12 + 9);  // default progression is A minor
    const int bins = sbe_track_waveform(tr, 441, nullptr, 0);
    CHECK(bins == int((t->frames + 440) / 441));
    sbe_track_release(tr);
}

TEST(wav_roundtrip_multichannel) {
    WavData w;
    w.channels = 4; w.sampleRate = 48000;
    for (int i = 0; i < 4800; ++i) for (int c = 0; c < 4; ++c) w.samples.push_back(float(std::sin(i * 0.01 * (c + 1))) * 0.5f);
    for (int bits : {16, 24, 32}) {
        const std::string path = "/tmp/sbe_test_" + std::to_string(bits) + ".wav";
        CHECK(writeWav(path, w, bits));
        WavData r;
        CHECK(readWav(path, r));
        CHECK(r.channels == 4 && r.frames() == 4800);
        double err = 0;
        for (size_t i = 0; i < w.samples.size(); ++i) err = std::max(err, double(std::fabs(w.samples[i] - r.samples[i])));
        CHECK(err < (bits == 16 ? 1e-4 : 1e-6));
    }
}

// ---- Performance budget ------------------------------------------------------------------
TEST(render_cost_budget) {
    Engine e(kSR, kBlock, 4);
    e.setOutputLayout({Topology::MultiChannel, 0, 1, 2, 3});
    synth::TrackSpec s; s.sampleRate = 44100; s.seconds = 20;
    auto t = synth::makeTrack(s); t->grid = {124, 0.25 * 44100};
    for (int d = 0; d < 4; ++d) {
        e.loadTrack(d, t);
        e.setFilter(d, 0.3f * float(d % 2 ? 1 : -1));
        e.setEcho(d, 0.3f, 0.75, 0.5f);
        e.setCueEnabled(d, d % 2 == 0);
        e.play(d);
    }
    e.previewLoad(t, 0); e.previewPlay();
    Capture warm(4);
    run(e, warm, 0.2);
    const double seconds = 10.0;
    const auto t0 = std::chrono::steady_clock::now();
    Capture cap(4);
    run(e, cap, seconds);
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    INFO("4 decks + preview + FX: %.2f%% of one core (real-time factor %.0fx)\n", elapsed / seconds * 100.0, seconds / elapsed);
    CHECK(elapsed / seconds < 0.25);  // generous: debug builds on CI must still pass
}

int main(int argc, char** argv) {
    const std::string filter = argc > 1 ? argv[1] : "";
    int ran = 0;
    for (auto& t : registry()) {
        if (!filter.empty() && std::string(t.name).find(filter) == std::string::npos) continue;
        const int before = g_failures;
        std::printf("[ RUN  ] %s\n", t.name);
        t.fn();
        std::printf("[ %s ] %s\n", g_failures == before ? " OK " : "FAIL", t.name);
        ++ran;
    }
    std::printf("\n%d tests, %d failed checks\n", ran, g_failures);
    return g_failures == 0 ? 0 : 1;
}
