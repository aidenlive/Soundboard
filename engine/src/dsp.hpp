// Soundboard Engine — real-time DSP primitives.
// Everything here is allocation-free after prepare() and safe to call on the audio thread.
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace sbe {

constexpr double kPi = 3.14159265358979323846;

inline float dbToGain(float db) { return db <= -80.0f ? 0.0f : std::pow(10.0f, db / 20.0f); }
inline float gainToDb(float g) { return g <= 1e-6f ? -120.0f : 20.0f * std::log10(g); }
inline float clampf(float v, float lo, float hi) { return std::min(hi, std::max(lo, v)); }

// 4-point, 3rd-order Hermite interpolation between x0 and x1 (t in [0,1)).
inline float hermite4(float xm1, float x0, float x1, float x2, float t) {
    const float c = (x1 - xm1) * 0.5f;
    const float v = x0 - x1;
    const float w = c + v;
    const float a = w + v + (x2 - x0) * 0.5f;
    const float b = w + a;
    return (((a * t) - b) * t + c) * t + x0;
}

// One-pole parameter smoother. Removes zipper noise from every user-facing control.
class SmoothedValue {
public:
    void reset(double sampleRate, double timeMs, float value) {
        coeff_ = timeMs <= 0.0 ? 0.0f : static_cast<float>(std::exp(-1.0 / (timeMs * 0.001 * sampleRate)));
        current_ = target_ = value;
    }
    void setTarget(float v) { target_ = v; }
    void snap(float v) { current_ = target_ = v; }
    float next() {
        const float n = target_ + (current_ - target_) * coeff_;
        // Snap when close, or when float rounding has stalled the decay a few ulps short of the
        // target (otherwise e.g. a crossfader parked at -1 would leak the far side at -140 dB).
        current_ = (n == current_ || std::fabs(n - target_) < 1e-6f) ? target_ : n;
        return current_;
    }
    float current() const { return current_; }
    float target() const { return target_; }
    bool isSmoothing() const { return current_ != target_; }

private:
    float coeff_ = 0.0f, current_ = 0.0f, target_ = 0.0f;
};

// Linear ramp with a fixed duration; deterministic endpoint (used for declicking transport).
class LinearRamp {
public:
    void reset(int lengthSamples, float value) {
        length_ = std::max(1, lengthSamples);
        current_ = target_ = value;
        step_ = 0.0f;
        remaining_ = 0;
    }
    void setTarget(float t) {
        if (t == target_ && remaining_ == 0) return;
        target_ = t;
        remaining_ = length_;
        step_ = (target_ - current_) / static_cast<float>(length_);
    }
    float next() {
        if (remaining_ > 0) {
            current_ += step_;
            if (--remaining_ == 0) current_ = target_;
        }
        return current_;
    }
    float current() const { return current_; }
    float target() const { return target_; }
    bool done() const { return remaining_ == 0; }

private:
    int length_ = 1, remaining_ = 0;
    float current_ = 0.0f, target_ = 0.0f, step_ = 0.0f;
};

// Transposed direct form II biquad with RBJ cookbook designs.
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float z1 = 0, z2 = 0;

    float process(float x) {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void clear() { z1 = z2 = 0; }

    enum class Type { LowPass, HighPass, AllPass, Peak, LowShelf, HighShelf };

    void design(Type type, double sampleRate, double freq, double q, double gainDb = 0.0) {
        freq = std::min(freq, sampleRate * 0.49);
        const double w0 = 2.0 * kPi * freq / sampleRate;
        const double cw = std::cos(w0), sw = std::sin(w0);
        const double alpha = sw / (2.0 * q);
        const double A = std::pow(10.0, gainDb / 40.0);
        double B0 = 1, B1 = 0, B2 = 0, A0 = 1, A1 = 0, A2 = 0;
        switch (type) {
            case Type::LowPass:
                B0 = (1 - cw) / 2; B1 = 1 - cw; B2 = (1 - cw) / 2;
                A0 = 1 + alpha; A1 = -2 * cw; A2 = 1 - alpha; break;
            case Type::HighPass:
                B0 = (1 + cw) / 2; B1 = -(1 + cw); B2 = (1 + cw) / 2;
                A0 = 1 + alpha; A1 = -2 * cw; A2 = 1 - alpha; break;
            case Type::AllPass:
                B0 = 1 - alpha; B1 = -2 * cw; B2 = 1 + alpha;
                A0 = 1 + alpha; A1 = -2 * cw; A2 = 1 - alpha; break;
            case Type::Peak:
                B0 = 1 + alpha * A; B1 = -2 * cw; B2 = 1 - alpha * A;
                A0 = 1 + alpha / A; A1 = -2 * cw; A2 = 1 - alpha / A; break;
            case Type::LowShelf: {
                const double s = 2 * std::sqrt(A) * alpha;
                B0 = A * ((A + 1) - (A - 1) * cw + s); B1 = 2 * A * ((A - 1) - (A + 1) * cw);
                B2 = A * ((A + 1) - (A - 1) * cw - s); A0 = (A + 1) + (A - 1) * cw + s;
                A1 = -2 * ((A - 1) + (A + 1) * cw); A2 = (A + 1) + (A - 1) * cw - s; break;
            }
            case Type::HighShelf: {
                const double s = 2 * std::sqrt(A) * alpha;
                B0 = A * ((A + 1) + (A - 1) * cw + s); B1 = -2 * A * ((A - 1) + (A + 1) * cw);
                B2 = A * ((A + 1) + (A - 1) * cw - s); A0 = (A + 1) - (A - 1) * cw + s;
                A1 = 2 * ((A - 1) - (A + 1) * cw); A2 = (A + 1) - (A - 1) * cw - s; break;
            }
        }
        b0 = float(B0 / A0); b1 = float(B1 / A0); b2 = float(B2 / A0);
        a1 = float(A1 / A0); a2 = float(A2 / A0);
    }
};

// DJ-style three-band isolator built from Linkwitz-Riley 4th-order crossovers.
// With all bands at unity the bands sum to an all-pass (flat magnitude), and any band can be
// fully killed — the behaviour DJs expect from a club mixer, unlike shelving EQs.
class IsolatorEq {
public:
    void prepare(double sampleRate, double lowXover = 250.0, double highXover = 2500.0) {
        constexpr double q = 0.70710678118654752;
        for (auto& ch : ch_) {
            ch.lp1a.design(Biquad::Type::LowPass, sampleRate, lowXover, q);
            ch.lp1b = ch.lp1a;
            ch.ap2.design(Biquad::Type::AllPass, sampleRate, highXover, q);
            ch.hp1a.design(Biquad::Type::HighPass, sampleRate, lowXover, q);
            ch.hp1b = ch.hp1a;
            ch.lp2a.design(Biquad::Type::LowPass, sampleRate, highXover, q);
            ch.lp2b = ch.lp2a;
            ch.hp2a.design(Biquad::Type::HighPass, sampleRate, highXover, q);
            ch.hp2b = ch.hp2a;
            ch.clear();
        }
        for (auto& g : gains_) g.reset(sampleRate, 15.0, 1.0f);
    }
    // dB, where <= -80 means full kill.
    void setBandDb(int band, float db) { gains_[band].setTarget(dbToGain(db)); }
    void snapBandDb(int band, float db) { gains_[band].snap(dbToGain(db)); }

    void process(float* left, float* right, int n) {
        for (int i = 0; i < n; ++i) {
            const float gl = gains_[0].next(), gm = gains_[1].next(), gh = gains_[2].next();
            left[i] = ch_[0].run(left[i], gl, gm, gh);
            right[i] = ch_[1].run(right[i], gl, gm, gh);
        }
    }

private:
    struct Chain {
        Biquad lp1a, lp1b, ap2, hp1a, hp1b, lp2a, lp2b, hp2a, hp2b;
        float run(float x, float gl, float gm, float gh) {
            const float low = ap2.process(lp1b.process(lp1a.process(x)));
            const float upper = hp1b.process(hp1a.process(x));
            const float mid = lp2b.process(lp2a.process(upper));
            const float high = hp2b.process(hp2a.process(upper));
            return low * gl + mid * gm + high * gh;
        }
        void clear() {
            for (Biquad* b : {&lp1a, &lp1b, &ap2, &hp1a, &hp1b, &lp2a, &lp2b, &hp2a, &hp2b}) b->clear();
        }
    };
    std::array<Chain, 2> ch_;
    std::array<SmoothedValue, 3> gains_;
};

// Topology-preserving-transform state variable filter (Zavalishin / Cytomic). Stable under
// fast cutoff modulation, which matters for a filter knob that is swept live.
class SvfFilter {
public:
    void setup(double sampleRate, double cutoff, double q) {
        cutoff = std::clamp(cutoff, 5.0, sampleRate * 0.49);
        g_ = std::tan(kPi * cutoff / sampleRate);
        k_ = 1.0 / q;
        a1_ = 1.0 / (1.0 + g_ * (g_ + k_));
        a2_ = g_ * a1_;
        a3_ = g_ * a2_;
    }
    void clear() { ic1_ = ic2_ = 0; }
    // Returns lowpass; writes highpass to *hp.
    float process(float x, float* hp) {
        const double v3 = x - ic2_;
        const double v1 = a1_ * ic1_ + a2_ * v3;
        const double v2 = ic2_ + a2_ * ic1_ + a3_ * v3;
        ic1_ = 2 * v1 - ic1_;
        ic2_ = 2 * v2 - ic2_;
        const double lp = v2;
        *hp = static_cast<float>(x - k_ * v1 - lp);
        return static_cast<float>(lp);
    }

private:
    double g_ = 0, k_ = 1.414, a1_ = 0, a2_ = 0, a3_ = 0, ic1_ = 0, ic2_ = 0;
};

// One-knob bipolar DJ filter: < 0 sweeps a low-pass down, > 0 sweeps a high-pass up.
// Implemented as an always-running LP→HP series pair so the centre position is transparent
// and crossing zero never switches topology (no clicks).
class DjFilter {
public:
    void prepare(double sampleRate) {
        sampleRate_ = sampleRate;
        knob_.reset(sampleRate, 20.0, 0.0f);
        for (auto& f : lp_) f.clear();
        for (auto& f : hp_) f.clear();
        updateCoefficients(0.0f);
    }
    void setKnob(float k) { knob_.setTarget(clampf(k, -1.0f, 1.0f)); }

    void process(float* left, float* right, int n) {
        int i = 0;
        while (i < n) {
            const int chunk = std::min(kControlInterval, n - i);
            float k = 0.0f;
            for (int j = 0; j < chunk; ++j) k = knob_.next();
            if (k == 0.0f && !knob_.isSmoothing() && lastKnob_ == 0.0f) { i += chunk; continue; }
            if (k != lastKnob_) updateCoefficients(k);
            for (int j = i; j < i + chunk; ++j) {
                float hpUnused, hpOut;
                const float l = lp_[0].process(left[j], &hpUnused);
                const float r = lp_[1].process(right[j], &hpUnused);
                hp_[0].process(l, &hpOut); left[j] = hpOut;
                hp_[1].process(r, &hpOut); right[j] = hpOut;
            }
            i += chunk;
        }
    }

private:
    static constexpr int kControlInterval = 16;
    void updateCoefficients(float k) {
        lastKnob_ = k;
        const double lpMax = std::min(20000.0, sampleRate_ * 0.45);
        const double hpMin = 10.0;
        const double a = std::fabs(k);
        const double q = 0.707 + 0.6 * a;
        // Exponential (musical) cutoff mapping.
        const double lpCut = k < 0 ? lpMax * std::pow(70.0 / lpMax, a) : lpMax;
        const double hpCut = k > 0 ? hpMin * std::pow(9000.0 / hpMin, a) : hpMin;
        for (auto& f : lp_) f.setup(sampleRate_, lpCut, k < 0 ? q : 0.707);
        for (auto& f : hp_) f.setup(sampleRate_, hpCut, k > 0 ? q : 0.707);
    }
    double sampleRate_ = 48000;
    float lastKnob_ = 1e9f;
    SmoothedValue knob_;
    std::array<SvfFilter, 2> lp_, hp_;
};

// Look-ahead brickwall peak limiter: min-hold over the look-ahead window followed by a box
// average of the same length guarantees the gain is already reduced when a peak arrives,
// so the output never exceeds the ceiling and the gain never steps instantaneously.
class LookaheadLimiter {
public:
    void prepare(double sampleRate, float lookaheadMs = 1.5f, float releaseMs = 120.0f) {
        L_ = std::max(1, int(lookaheadMs * 0.001 * sampleRate));
        delayL_.assign(L_, 0.0f);
        delayR_.assign(L_, 0.0f);
        boxWindow_.assign(L_ + 1, 1.0f);
        dequeIdx_.assign(2 * (L_ + 2), 0);
        dequeVal_.assign(2 * (L_ + 2), 1.0f);
        head_ = tail_ = 0;
        writePos_ = 0;
        boxPos_ = 0;
        counter_ = 0;
        boxSum_ = double(L_ + 1);
        release_ = std::exp(-1.0f / (releaseMs * 0.001f * float(sampleRate)));
        gain_ = 1.0f;
        gainReduction_ = 0.0f;
    }
    void setCeilingDb(float db) { ceiling_ = dbToGain(db); }
    float lastGainReductionDb() const { return gainReduction_; }
    int latencySamples() const { return L_; }

    void process(float* left, float* right, int n) {
        float minGain = 1.0f;
        const int size = L_ + 1;
        for (int i = 0; i < n; ++i) {
            const float peak = std::max(std::fabs(left[i]), std::fabs(right[i]));
            const float req = peak > ceiling_ ? ceiling_ / peak : 1.0f;
            const float held = pushMin(req);
            // Box average (L+1 taps) of the held minimum. Every window averaged here contains
            // the sample leaving the L-sample delay line, so the result never exceeds its need.
            boxSum_ += held - boxWindow_[boxPos_];
            boxWindow_[boxPos_] = held;
            boxPos_ = (boxPos_ + 1) % size;
            const float target = std::min(1.0f, float(boxSum_ / size));
            // Gain may fall immediately (already smoothed by the box), rises with release.
            gain_ = target < gain_ ? target : target + (gain_ - target) * release_;
            // L-sample delay line.
            const int pos = writePos_;
            const float dl = delayL_[pos], dr = delayR_[pos];
            delayL_[pos] = left[i];
            delayR_[pos] = right[i];
            writePos_ = (pos + 1) % L_;
            float ol = dl * gain_, orr = dr * gain_;
            // Numerical safety only — never expected to engage.
            ol = clampf(ol, -ceiling_, ceiling_);
            orr = clampf(orr, -ceiling_, ceiling_);
            left[i] = ol;
            right[i] = orr;
            minGain = std::min(minGain, gain_);
        }
        gainReduction_ = -gainToDb(minGain);
    }

private:
    // Monotonic deque sliding-window minimum over the last L+1 samples.
    float pushMin(float v) {
        const int cap = int(dequeVal_.size());
        while (head_ != tail_) {
            const int last = (tail_ - 1 + cap) % cap;
            if (dequeVal_[last] >= v) tail_ = last; else break;
        }
        dequeVal_[tail_] = v;
        dequeIdx_[tail_] = counter_;
        tail_ = (tail_ + 1) % cap;
        while (dequeIdx_[head_] <= counter_ - (L_ + 1)) head_ = (head_ + 1) % cap;
        ++counter_;
        return dequeVal_[head_];
    }

    int L_ = 1, writePos_ = 0, boxPos_ = 0, head_ = 0, tail_ = 0;
    int64_t counter_ = 0;
    std::vector<float> delayL_, delayR_, boxWindow_, dequeVal_;
    std::vector<int64_t> dequeIdx_;
    double boxSum_ = 0;
    float ceiling_ = dbToGain(-0.3f), release_ = 0.999f, gain_ = 1.0f, gainReduction_ = 0.0f;
};

// Stereo delay line with integer delay that can be changed without clicks (crossfaded).
class CompensationDelay {
public:
    void prepare(int maxFrames) {
        buf_[0].assign(maxFrames + 1, 0.0f);
        buf_[1].assign(maxFrames + 1, 0.0f);
        pos_ = 0;
        delay_ = 0;
        pending_ = 0;
        fade_.reset(256, 1.0f);
    }
    void setDelay(int frames) {
        pending_ = std::clamp(frames, 0, int(buf_[0].size()) - 1);
    }
    int delay() const { return delay_; }
    void process(float* l, float* r, int n) {
        const int size = int(buf_[0].size());
        for (int i = 0; i < n; ++i) {
            if (pending_ != delay_ && fade_.done()) {
                if (fade_.current() > 0.0f) fade_.setTarget(0.0f);
                else { delay_ = pending_; fade_.setTarget(1.0f); }
            }
            buf_[0][pos_] = l[i];
            buf_[1][pos_] = r[i];
            const int rp = (pos_ - delay_ + size) % size;
            const float g = fade_.next();
            l[i] = buf_[0][rp] * g;
            r[i] = buf_[1][rp] * g;
            pos_ = (pos_ + 1) % size;
        }
    }

private:
    std::array<std::vector<float>, 2> buf_;
    int pos_ = 0, delay_ = 0, pending_ = 0;
    LinearRamp fade_;
};

// Beat-synced stereo echo with filtered feedback. Post-fader so its tail survives an
// "echo out" when the channel fader is cut.
class BeatEcho {
public:
    void prepare(double sampleRate, double maxSeconds = 4.0) {
        sampleRate_ = sampleRate;
        const int n = int(maxSeconds * sampleRate) + 4;
        buf_[0].assign(n, 0.0f);
        buf_[1].assign(n, 0.0f);
        pos_ = 0;
        delay_.reset(sampleRate, 60.0, float(sampleRate * 0.5));
        wet_.reset(sampleRate, 20.0, 0.0f);
        send_.reset(sampleRate, 5.0, 0.0f);
        lpState_[0] = lpState_[1] = 0.0f;
        lpCoeff_ = float(std::exp(-2.0 * kPi * 4500.0 / sampleRate));
        active_ = false;
        tailEnergy_ = 0.0f;
    }
    void setWet(float w) { wet_.setTarget(clampf(w, 0, 1)); send_.setTarget(w > 0 ? 1.0f : 0.0f); if (w > 0) active_ = true; }
    void setFeedback(float f) { feedback_ = clampf(f, 0.0f, 0.95f); }
    void setTiming(double bpm, double beats) {
        if (bpm <= 0) bpm = 120;
        const double secs = std::min(60.0 / bpm * beats, double(buf_[0].size() - 4) / sampleRate_);
        delay_.setTarget(float(secs * sampleRate_));
    }
    bool isActive() const { return active_; }

    void process(float* l, float* r, int n) {
        if (!active_) return;
        const int size = int(buf_[0].size());
        float energy = 0.0f;
        for (int i = 0; i < n; ++i) {
            const float d = delay_.next();
            float rp = float(pos_) - d;
            while (rp < 0) rp += float(size);
            const int i0 = int(rp);
            const float frac = rp - float(i0);
            const int i1 = (i0 + 1) % size;
            const float el = buf_[0][i0] + (buf_[0][i1] - buf_[0][i0]) * frac;
            const float er = buf_[1][i0] + (buf_[1][i1] - buf_[1][i0]) * frac;
            lpState_[0] = el + (lpState_[0] - el) * lpCoeff_;
            lpState_[1] = er + (lpState_[1] - er) * lpCoeff_;
            const float s = send_.next();
            buf_[0][pos_] = l[i] * s + lpState_[0] * feedback_;
            buf_[1][pos_] = r[i] * s + lpState_[1] * feedback_;
            pos_ = (pos_ + 1) % size;
            const float w = wet_.next();
            l[i] += el * w;
            r[i] += er * w;
            energy = std::max(energy, std::fabs(el) + std::fabs(er));
        }
        // Keep running while the tail is audible; then go idle to save CPU.
        tailEnergy_ = energy;
        if (send_.target() == 0.0f && !send_.isSmoothing() && tailEnergy_ < 1e-5f) {
            active_ = false;
            std::fill(buf_[0].begin(), buf_[0].end(), 0.0f);
            std::fill(buf_[1].begin(), buf_[1].end(), 0.0f);
        }
    }
    // Stop feeding new audio but let the tail ring out (wet stays up).
    void releaseInput() { send_.setTarget(0.0f); }

private:
    std::array<std::vector<float>, 2> buf_;
    int pos_ = 0;
    double sampleRate_ = 48000;
    SmoothedValue delay_, wet_, send_;
    float feedback_ = 0.55f, lpCoeff_ = 0.5f, tailEnergy_ = 0.0f;
    std::array<float, 2> lpState_{};
    bool active_ = false;
};

// Peak meter with hold/decay computed once per block.
struct PeakMeter {
    float value = 0.0f;
    void update(const float* l, const float* r, int n, float decay) {
        float p = 0.0f;
        for (int i = 0; i < n; ++i) p = std::max(p, std::max(std::fabs(l[i]), std::fabs(r[i])));
        value = std::max(p, value * decay);
    }
};

}  // namespace sbe
