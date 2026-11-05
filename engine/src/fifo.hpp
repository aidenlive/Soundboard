// Soundboard Engine — lock-free single-producer/single-consumer queues.
#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "dsp.hpp"

namespace sbe {

// Bounded SPSC queue of trivially copyable messages (UI thread -> audio thread and back).
template <typename T>
class SpscQueue {
public:
    explicit SpscQueue(size_t capacityPow2 = 1024) : buf_(capacityPow2), mask_(capacityPow2 - 1) {}
    bool push(const T& v) {
        const size_t w = write_.load(std::memory_order_relaxed);
        const size_t r = read_.load(std::memory_order_acquire);
        if (w - r >= buf_.size()) return false;
        buf_[w & mask_] = v;
        write_.store(w + 1, std::memory_order_release);
        return true;
    }
    bool pop(T& out) {
        const size_t r = read_.load(std::memory_order_relaxed);
        const size_t w = write_.load(std::memory_order_acquire);
        if (r == w) return false;
        out = buf_[r & mask_];
        read_.store(r + 1, std::memory_order_release);
        return true;
    }

private:
    std::vector<T> buf_;
    size_t mask_;
    alignas(64) std::atomic<size_t> write_{0};
    alignas(64) std::atomic<size_t> read_{0};
};

// Interleaved stereo sample ring (audio thread -> recorder / secondary device thread).
class StereoRing {
public:
    void prepare(size_t frames) {
        size_t cap = 1;
        while (cap < frames) cap <<= 1;
        buf_.assign(cap * 2, 0.0f);
        mask_ = cap - 1;
        write_.store(0);
        read_.store(0);
    }
    size_t capacity() const { return mask_ + 1; }
    size_t available() const { return write_.load(std::memory_order_acquire) - read_.load(std::memory_order_acquire); }
    size_t space() const { return capacity() - available(); }

    // Returns frames written (drops the overflow, never blocks).
    size_t write(const float* l, const float* r, size_t n) {
        const size_t w = write_.load(std::memory_order_relaxed);
        const size_t rd = read_.load(std::memory_order_acquire);
        const size_t free = capacity() - (w - rd);
        const size_t todo = std::min(n, free);
        for (size_t i = 0; i < todo; ++i) {
            const size_t idx = ((w + i) & mask_) * 2;
            buf_[idx] = l[i];
            buf_[idx + 1] = r[i];
        }
        write_.store(w + todo, std::memory_order_release);
        return todo;
    }
    size_t readInterleaved(float* dst, size_t maxFrames) {
        const size_t rd = read_.load(std::memory_order_relaxed);
        const size_t w = write_.load(std::memory_order_acquire);
        const size_t todo = std::min(maxFrames, w - rd);
        for (size_t i = 0; i < todo; ++i) {
            const size_t idx = ((rd + i) & mask_) * 2;
            dst[2 * i] = buf_[idx];
            dst[2 * i + 1] = buf_[idx + 1];
        }
        read_.store(rd + todo, std::memory_order_release);
        return todo;
    }
    // Peek a frame relative to the read head without consuming.
    void peek(size_t offset, float& l, float& r) const {
        const size_t idx = ((read_.load(std::memory_order_relaxed) + offset) & mask_) * 2;
        l = buf_[idx];
        r = buf_[idx + 1];
    }
    void advance(size_t n) { read_.store(read_.load(std::memory_order_relaxed) + n, std::memory_order_release); }

private:
    std::vector<float> buf_;
    size_t mask_ = 0;
    alignas(64) std::atomic<size_t> write_{0};
    alignas(64) std::atomic<size_t> read_{0};
};

// Bridges a bus rendered on one device clock to a second device with its own clock
// (e.g. master on a USB interface, cue on the built-in headphone jack, both on macOS or
// Android). The consumer resamples with a ratio steered by a PI controller on the FIFO fill
// level, absorbing crystal drift (typically ±100 ppm) without underruns or audible jumps.
class DriftCompensatedFifo {
public:
    // targetFillFrames must exceed producer block + consumer block (plus scheduling margin).
    void prepare(int targetFillFrames, int capacityFrames, double nominalRate = 48000.0) {
        ring_.prepare(size_t(std::max(capacityFrames, targetFillFrames * 4)));
        target_ = double(targetFillFrames);
        rate_ = nominalRate;
        frac_ = 0.0;
        ratio_ = 1.0;
        integral_ = 0.0;
        filteredFill_ = target_;
        primed_ = false;
        underruns_.store(0);
    }
    // Producer side (primary device callback).
    void push(const float* l, const float* r, int n) { ring_.write(l, r, size_t(n)); }

    // Consumer side (secondary device callback).
    void pull(float* l, float* r, int n) {
        const double avail = double(ring_.available());
        if (!primed_) {
            if (avail < target_) { std::fill(l, l + n, 0.0f); std::fill(r, r + n, 0.0f); return; }
            primed_ = true;
            filteredFill_ = avail - 0.5 * n;
        }
        // PI controller on the (heavily smoothed) fill level. Block-granular callbacks make the
        // observed fill move in whole-buffer steps ("slips"), so it is averaged over ~2 s; the
        // proportional time constant is ~8 s and the integral (which converges to the true clock
        // ratio) ~60 s. The resulting pitch deviation stays around a cent — inaudible on a
        // headphone cue feed — while drift of several hundred ppm never underruns.
        const double dt = double(n) / rate_;
        // Mean level during this callback (the buffer drains by n while it plays).
        filteredFill_ += std::min(1.0, dt / 2.0) * (avail - 0.5 * n - filteredFill_);
        const double errFrames = filteredFill_ - target_;
        const double kp = 1.0 / (8.0 * rate_);  // ratio per frame of error
        integral_ = std::clamp(integral_ + kp / 60.0 * errFrames * dt, -3e-3, 3e-3);
        ratio_ = std::clamp(1.0 + kp * errFrames + integral_, 0.995, 1.005);

        for (int i = 0; i < n; ++i) {
            if (ring_.available() < 4) {
                // Underrun: fade to silence and re-prime.
                underruns_.fetch_add(1, std::memory_order_relaxed);
                for (int j = i; j < n; ++j) { l[j] = 0.0f; r[j] = 0.0f; }
                primed_ = false;
                return;
            }
            float l0, r0, l1, r1, lm, rm, l2, r2;
            ring_.peek(0, lm, rm);
            ring_.peek(1, l0, r0);
            ring_.peek(2, l1, r1);
            ring_.peek(3, l2, r2);
            const float t = float(frac_);
            l[i] = hermite4(lm, l0, l1, l2, t);
            r[i] = hermite4(rm, r0, r1, r2, t);
            frac_ += ratio_;
            const int adv = int(frac_);
            frac_ -= adv;
            if (adv) ring_.advance(size_t(adv));
        }
    }
    double ratio() const { return ratio_; }
    double fill() const { return double(ring_.available()); }
    uint32_t underruns() const { return underruns_.load(); }


private:
    StereoRing ring_;
    double target_ = 512, rate_ = 48000, frac_ = 0, ratio_ = 1, integral_ = 0, filteredFill_ = 0;
    bool primed_ = false;
    std::atomic<uint32_t> underruns_{0};
};

}  // namespace sbe
