#include "deck.hpp"

#include <cmath>

namespace sbe {

void Deck::prepare(double outputRate) {
    outRate_ = outputRate;
    smoothRate_.reset(outputRate, 25.0, 1.0f);
    speedGain_.reset(outputRate, 2.0, 0.0f);
    playGain_.reset(int(0.004 * outputRate), 0.0f);  // 4 ms start/stop declick
    xfadeLen_ = std::max(32, int(0.003 * outputRate)); // 3 ms jump crossfade
    hotCues_.fill(-1.0);
}

void Deck::setTrack(const AudioBuffer* track) {
    track_ = track;
    pos_ = oldPos_ = 0.0;
    playing_ = false;
    ended_ = false;
    cueHeld_ = false;
    playGain_.reset(int(0.004 * outRate_), 0.0f);
    xfadeRemaining_ = 0;
    tempo_ = 1.0;
    nudge_ = 1.0;
    syncCorrection_ = 1.0;
    smoothRate_.snap(1.0f);
    loopActive_ = false;
    hotCues_.fill(-1.0);
    cuePoint_ = (track && track->grid.valid()) ? track->grid.firstBeatFrame : 0.0;
    pos_ = cuePoint_;
    platter_ = false; touched_ = false; vel_ = 0.0; bend_ = 0.0;
    speedGain_.snap(0.0f);
}

double Deck::clampFrame(double f) const {
    if (!loaded()) return 0.0;
    return std::clamp(f, 0.0, double(track_->frames - 1));
}

float Deck::sampleAt(double pos, int ch) const {
    const int64_t i0 = int64_t(std::floor(pos));
    const float t = float(pos - double(i0));
    const int64_t n = track_->frames;
    const float* s = track_->samples.data();
    auto at = [&](int64_t i) -> float { return (i < 0 || i >= n) ? 0.0f : s[2 * i + ch]; };
    return hermite4(at(i0 - 1), at(i0), at(i0 + 1), at(i0 + 2), t);
}

void Deck::render(float* l, float* r, int n) {
    if (!loaded()) {
        std::fill(l, l + n, 0.0f);
        std::fill(r, r + n, 0.0f);
        return;
    }
    const double srcRatio = track_->sampleRate / outRate_;
    // The jog edge's bend decays with a 80 ms time constant.
    if (bend_ != 0.0) {
        bend_ *= std::exp(-double(n) / (0.08 * outRate_));
        if (std::fabs(bend_) < 1e-5) bend_ = 0.0;
    }
    if (platter_) {
        renderPlatter(l, r, n, srcRatio);
        return;
    }
    smoothRate_.setTarget(float(effectiveRate() * bendFactor()));
    const double end = double(track_->frames);
    for (int i = 0; i < n; ++i) {
        const float g = playGain_.next();
        const double step = double(smoothRate_.next()) * srcRatio;
        float outL = 0.0f, outR = 0.0f;
        const bool audible = g > 0.0f || xfadeRemaining_ > 0;
        if (audible) {
            outL = sampleAt(pos_, 0) * g;
            outR = sampleAt(pos_, 1) * g;
            if (xfadeRemaining_ > 0) {
                const float a = float(xfadeRemaining_) / float(xfadeLen_);
                outL = outL * (1.0f - a) + sampleAt(oldPos_, 0) * oldGain_ * a;
                outR = outR * (1.0f - a) + sampleAt(oldPos_, 1) * oldGain_ * a;
                oldPos_ += step;
                --xfadeRemaining_;
            }
        }
        l[i] = outL;
        r[i] = outR;
        // Advance while playing or while the stop ramp is still sounding.
        if (playing_ || g > 0.0f) {
            pos_ += step;
            if (loopActive_ && pos_ >= loopOut_ && loopOut_ > loopIn_) {
                jumpTo(loopIn_ + std::fmod(pos_ - loopOut_, loopOut_ - loopIn_));
            }
            if (pos_ >= end) {
                pos_ = end - 1;
                playing_ = false;
                ended_ = true;
                playGain_.reset(int(0.004 * outRate_), 0.0f);
            }
        }
    }
}

// The platter: a hand (or the motor) moves the record; the read head follows it.
// Like a phono cartridge, output level follows groove speed: a still record is silent, a slow
// one quiet and low, so stopping and reversing never click.
void Deck::renderPlatter(float* l, float* r, int n, double srcRatio) {
    const double end = double(track_->frames);
    const double maxVel = 8.0 * srcRatio;
    // The read head chases the hand with a ~6 ms follow time and ~2 ms velocity smoothing:
    // fast enough to feel direct, smooth enough that 60–120 Hz touch events never zipper.
    const double follow = 1.0 / (0.006 * outRate_);
    const double smooth = 1.0 - std::exp(-1.0 / (0.002 * outRate_));
    for (int i = 0; i < n; ++i) {
        if (touched_) {
            const double desired = std::clamp((hand_ - pos_) * follow, -maxVel, maxVel);
            vel_ += (desired - vel_) * smooth;
        } else {
            const double target = motorTarget(srcRatio);
            if (vel_ < target) vel_ = std::min(target, vel_ + rampStep_);
            else vel_ = std::max(target, vel_ - rampStep_);
            if (vel_ == target) {
                // Motor at speed (or stopped): hand back to the normal transport.
                platter_ = false;
                smoothRate_.snap(float(target / srcRatio));
                playGain_.reset(int(0.004 * outRate_), playing_ ? 1.0f : 0.0f);
                for (int k = i; k < n; ++k) { l[k] = 0.0f; r[k] = 0.0f; }
                // Render the rest of the block normally so there is no gap.
                if (i < n) render(l + i, r + i, n - i);
                return;
            }
        }
        // Full level from half speed up (so tempo changes never change level), fading to silence
        // as the record stops.
        const double speed = std::fabs(vel_) / srcRatio;      // 1 = normal speed
        speedGain_.setTarget(float(std::min(1.0, 2.0 * speed)));
        const float g = speedGain_.next();
        l[i] = sampleAt(pos_, 0) * g;
        r[i] = sampleAt(pos_, 1) * g;
        pos_ += vel_;
        if (pos_ < 0.0) { pos_ = 0.0; if (vel_ < 0) vel_ = 0.0; }
        if (pos_ > end - 1.0) {
            pos_ = end - 1.0;
            vel_ = 0.0;
            if (!touched_) { playing_ = false; ended_ = true; }
        }
        if (!touched_ && loopActive_ && vel_ > 0 && pos_ >= loopOut_ && loopOut_ > loopIn_) {
            pos_ = loopIn_ + std::fmod(pos_ - loopOut_, loopOut_ - loopIn_);
        }
    }
}

void Deck::touch(bool on) {
    if (!loaded() || on == touched_) return;
    if (on) {
        if (!platter_) {
            // Pick the record up at the speed it is turning, so the hand catches it smoothly.
            const double srcRatio = track_->sampleRate / outRate_;
            const bool sounding = playing_ || playGain_.current() > 0.0f;
            vel_ = sounding ? double(smoothRate_.current()) * srcRatio : 0.0;
            speedGain_.snap(sounding ? float(std::min(1.0, 2.0 * double(smoothRate_.current()))) : 0.0f);
            xfadeRemaining_ = 0;
        }
        touched_ = true;
        platter_ = true;
        hand_ = pos_;
        ended_ = false;
    } else {
        touched_ = false;
        startMotorRamp();
    }
}

void Deck::scratch(double revolutions) {
    if (!touched_ || !loaded()) return;
    hand_ = std::clamp(hand_ + revolutions * kSecondsPerRevolution * track_->sampleRate,
                       -0.5 * track_->sampleRate, double(track_->frames));
}

void Deck::bend(double revolutions) {
    if (!loaded() || touched_) return;
    // A quarter turn of the edge ≈ +8 % for a moment.
    bend_ = std::clamp(bend_ + revolutions * 0.32, -0.5, 0.5);
}

void Deck::startMotorRamp() {
    const double srcRatio = track_ ? track_->sampleRate / outRate_ : 1.0;
    const double nominal = std::max(0.05, effectiveRate()) * srcRatio;
    // Turntable: full speed in `motorSeconds_`. CDJ-style: 30 ms, just enough to avoid a click.
    const double seconds = motorSeconds_ > 0.0 ? motorSeconds_ : 0.03;
    rampStep_ = nominal / (seconds * outRate_);
}

void Deck::jumpTo(double frame) {
    // Equal-length linear crossfade from the old read head to the new one.
    oldPos_ = pos_;
    oldGain_ = playGain_.current();
    pos_ = clampFrame(frame);
    xfadeRemaining_ = xfadeLen_;
    if (touched_) hand_ = pos_;   // a hot cue under the hand moves the record
    ended_ = false;
}

void Deck::play() {
    if (!loaded()) return;
    if (ended_) { ended_ = false; }
    playing_ = true;
    cueHeld_ = false;
    if (motorSeconds_ > 0.0 && !platter_) {
        // Turntable start: the record spins up from rest.
        platter_ = true;
        vel_ = 0.0;
        speedGain_.snap(0.0f);
        startMotorRamp();
        return;
    }
    if (platter_ && !touched_) { startMotorRamp(); return; }   // re-started during a brake
    if (!platter_) playGain_.setTarget(1.0f);
}

void Deck::pause() {
    const bool wasPlaying = playing_;
    playing_ = false;
    cueHeld_ = false;
    if (motorSeconds_ > 0.0 && wasPlaying && !platter_ && loaded()) {
        // Turntable brake: the record slows to a stop.
        const double srcRatio = track_->sampleRate / outRate_;
        platter_ = true;
        vel_ = double(smoothRate_.current()) * srcRatio;
        speedGain_.snap(float(std::min(1.0, 2.0 * double(smoothRate_.current()))));
        startMotorRamp();
        return;
    }
    if (platter_ && !touched_) { startMotorRamp(); return; }   // stopped during a spin-up
    if (!platter_) playGain_.setTarget(0.0f);
}

void Deck::seek(double frame) {
    if (!loaded()) return;
    jumpTo(frame);
}

void Deck::cuePress(bool quantize) {
    if (!loaded()) return;
    if (playing_ && !cueHeld_) {
        // Return to cue and stop: old audio fades out via the jump crossfade.
        jumpTo(cuePoint_);
        playing_ = false;
        playGain_.reset(int(0.004 * outRate_), 0.0f);
        return;
    }
    if (std::fabs(pos_ - cuePoint_) < 2.0) {
        // Momentary preview from the cue point while held.
        playing_ = true;
        cueHeld_ = true;
        playGain_.setTarget(1.0f);
        return;
    }
    double f = pos_;
    if (quantize && track_->grid.valid()) f = track_->grid.nearestBeatFrame(f, track_->sampleRate);
    cuePoint_ = clampFrame(f);
    if (std::fabs(cuePoint_ - pos_) >= 1.0) jumpTo(cuePoint_);
}

void Deck::cueRelease() {
    if (!cueHeld_) return;
    cueHeld_ = false;
    jumpTo(cuePoint_);
    playing_ = false;
    playGain_.reset(int(0.004 * outRate_), 0.0f);
}

void Deck::triggerHotCue(int i, bool quantize) {
    if (!loaded() || i < 0 || i >= kHotCues) return;
    if (hotCues_[i] < 0.0) {
        double f = pos_;
        if (quantize && track_->grid.valid()) f = track_->grid.nearestBeatFrame(f, track_->sampleRate);
        hotCues_[i] = clampFrame(f);
        return;
    }
    jumpTo(hotCues_[i]);
    play();
}

double Deck::beatLengthFrames() const {
    if (!loaded()) return 0.0;
    const double bpm = track_->grid.valid() ? track_->grid.bpm : 120.0;
    return 60.0 / bpm * track_->sampleRate;
}

double Deck::beatPosition() const {
    if (!loaded()) return 0.0;
    const BeatGrid g = track_->grid.valid() ? track_->grid : BeatGrid{120.0, 0.0};
    return g.beatAt(pos_, track_->sampleRate);
}

void Deck::setBeatLoop(double beats, bool quantize) {
    if (!loaded() || beats <= 0) return;
    double in = pos_;
    if (quantize && track_->grid.valid()) {
        // Snap to the beat at or just before the play head so the loop engages immediately.
        const double b = std::floor(track_->grid.beatAt(pos_, track_->sampleRate) + 1e-6);
        in = track_->grid.frameOfBeat(b, track_->sampleRate);
    }
    setLoop(in, in + beats * beatLengthFrames());
}

void Deck::setLoop(double inFrame, double outFrame) {
    if (!loaded() || outFrame <= inFrame) return;
    loopIn_ = clampFrame(inFrame);
    loopOut_ = std::min(outFrame, double(track_->frames));
    loopActive_ = true;
}

void Deck::reloop() {
    if (loopOut_ > loopIn_) {
        loopActive_ = true;
        if (pos_ >= loopOut_ || pos_ < loopIn_) jumpTo(loopIn_);
    }
}

void Deck::scaleLoop(double factor) {
    if (!loopActive_ || factor <= 0) return;
    const double len = (loopOut_ - loopIn_) * factor;
    if (len < 8.0) return;
    loopOut_ = std::min(loopIn_ + len, double(track_->frames));
    if (pos_ >= loopOut_) jumpTo(loopIn_ + std::fmod(pos_ - loopIn_, loopOut_ - loopIn_));
}

void Deck::beatJump(double beats) {
    if (!loaded()) return;
    const double delta = beats * beatLengthFrames();
    if (loopActive_) {
        loopIn_ += delta;
        loopOut_ += delta;
    }
    jumpTo(pos_ + delta);
}

}  // namespace sbe
