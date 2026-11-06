// Soundboard Engine — a playback deck. Audio-thread only.
#pragma once

#include <array>
#include <cstdint>

#include "dsp.hpp"
#include "track.hpp"

namespace sbe {

constexpr int kHotCues = 8;

class Deck {
public:
    void prepare(double outputRate);

    // Swap the track (pointer lifetime is guaranteed by the Engine's deferred release).
    void setTrack(const AudioBuffer* track);
    const AudioBuffer* track() const { return track_; }
    bool loaded() const { return track_ != nullptr && track_->frames > 0; }

    // Renders n frames (overwrites l/r).
    void render(float* l, float* r, int n);

    // Transport.
    void play();
    void pause();
    void togglePlay() { playing_ ? pause() : play(); }
    bool playing() const { return playing_; }
    void seek(double frame);            // crossfaded jump
    void cuePress(bool quantize);       // CDJ-style cue semantics
    void cueRelease();
    void setCuePoint(double frame) { cuePoint_ = clampFrame(frame); }
    double cuePoint() const { return cuePoint_; }

    void setHotCue(int i, double frame) { if (i >= 0 && i < kHotCues) hotCues_[i] = clampFrame(frame); }
    void triggerHotCue(int i, bool quantize);  // sets if empty, otherwise jumps + plays
    void clearHotCue(int i) { if (i >= 0 && i < kHotCues) hotCues_[i] = -1.0; }
    double hotCue(int i) const { return (i >= 0 && i < kHotCues) ? hotCues_[i] : -1.0; }

    // Loops & beat jump (in beats of the track's grid; 120 BPM assumed when no grid).
    void setBeatLoop(double beats, bool quantize);
    void setLoop(double inFrame, double outFrame);
    void exitLoop() { loopActive_ = false; }
    void reloop();
    void scaleLoop(double factor);
    bool loopActive() const { return loopActive_; }
    double loopIn() const { return loopIn_; }
    double loopOut() const { return loopOut_; }
    void beatJump(double beats);

    // Tempo.
    void setTempo(double ratio) { tempo_ = std::clamp(ratio, 0.25, 4.0); }
    double tempo() const { return tempo_; }
    void setNudge(double ratio) { nudge_ = std::clamp(ratio, 0.9, 1.1); }
    void setSyncCorrection(double ratio) { syncCorrection_ = ratio; }
    double effectiveRate() const { return tempo_ * nudge_ * syncCorrection_; }
    double effectiveBpm() const { return loaded() && track_->grid.valid() ? track_->grid.bpm * tempo_ : 0.0; }
    double beatPosition() const;  // fractional beat index at the play head
    double beatLengthFrames() const;

    double position() const { return pos_; }
    bool ended() const { return ended_; }

    // Vinyl / platter (the jog wheel). One revolution = 1.8 s of audio (33⅓ rpm).
    //  touch(true)   hand on the record: it follows the hand, stopping if the hand is still.
    //  scratch(rev)  move the hand by `rev` revolutions (signed) while touched.
    //  touch(false)  let go: the motor brings it back to speed (or to rest if paused).
    //  bend(rev)     turn the jog's edge: a temporary pitch bend that decays (beat-matching by hand).
    //  setMotorTime  0 = instant start and stop (CDJ); > 0 = turntable spin-up / brake time.
    static constexpr double kSecondsPerRevolution = 1.8;
    void touch(bool on);
    void scratch(double revolutions);
    void bend(double revolutions);
    void setMotorTime(double seconds) { motorSeconds_ = std::clamp(seconds, 0.0, 4.0); }
    bool touched() const { return touched_; }

private:
    double clampFrame(double f) const;
    void jumpTo(double frame);
    float sampleAt(double pos, int ch) const;
    void renderPlatter(float* l, float* r, int n, double srcRatio);
    void startMotorRamp();
    double motorTarget(double srcRatio) const { return playing_ ? effectiveRate() * bendFactor() * srcRatio : 0.0; }
    double bendFactor() const { return 1.0 + std::clamp(bend_, -0.5, 0.5); }

    const AudioBuffer* track_ = nullptr;
    double outRate_ = 48000.0;
    double pos_ = 0.0, oldPos_ = 0.0;
    double tempo_ = 1.0, nudge_ = 1.0, syncCorrection_ = 1.0;
    SmoothedValue smoothRate_;
    LinearRamp playGain_;
    float oldGain_ = 0.0f;
    int xfadeLen_ = 128, xfadeRemaining_ = 0;
    bool playing_ = false, ended_ = false, cueHeld_ = false;
    double cuePoint_ = 0.0;
    std::array<double, kHotCues> hotCues_{};
    bool loopActive_ = false;
    double loopIn_ = 0.0, loopOut_ = 0.0;

    // Platter state. While `platter_` is set the deck is driven by `vel_` (track frames per output
    // frame, signed) instead of the smoothed tempo: during a scratch, and while the motor ramps.
    bool platter_ = false, touched_ = false;
    double vel_ = 0.0, hand_ = 0.0, rampStep_ = 0.0;
    double bend_ = 0.0, motorSeconds_ = 0.0;
    SmoothedValue speedGain_;
};

}  // namespace sbe
