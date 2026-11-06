// Soundboard Engine — mixer, buses, routing and the thread boundary.
//
// Threading model
//   * Control thread (UI / app logic): calls the public "control" methods. They never touch
//     audio state directly; they enqueue a Command on a lock-free SPSC queue.
//   * Audio thread (device callback): calls render(). It drains the queue at the start of each
//     callback, so every change is applied sample-accurately at a block boundary and the audio
//     thread never locks, allocates or frees.
//   * Track memory is owned by the control thread and released only after the audio thread has
//     acknowledged the swap (generation counter), so a free never happens on the audio thread.
//   * Status for the UI is published through relaxed atomics (snapshot()).
#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include "deck.hpp"
#include "dsp.hpp"
#include "fifo.hpp"
#include "track.hpp"

namespace sbe {

constexpr int kMaxDecks = 4;
constexpr int kPreviewSlot = kMaxDecks;  // track slot used by the library preview player

// How the two logical buses (Master, Headphones/Cue) map onto physical outputs.
enum class Topology : int {
    MasterOnly = 0,        // one stereo output; private cueing unavailable
    SplitMono = 1,         // one stereo jack + DJ splitter cable: L = master mono, R = cue mono
    MultiChannel = 2,      // one multichannel device: master on one pair, cue on another
    SeparateCueDevice = 3  // two devices with independent clocks: cue pulled by renderCue()
};

struct OutputLayout {
    Topology topology = Topology::MasterOnly;
    int masterLeft = 0, masterRight = 1;
    int cueLeft = 2, cueRight = 3;  // SplitMono uses masterLeft and cueLeft only
};

enum class XfAssign : int { Thru = 0, A = 1, B = 2 };
enum class TransitionStyle : int { Blend = 0, BassSwap = 1, FilterSweep = 2, EchoOut = 3 };
enum class EqBand : int { Low = 0, Mid = 1, High = 2 };

struct DeckStatus {
    bool loaded = false, playing = false, loopActive = false, syncLocked = false, cueEnabled = false, touched = false;
    double position = 0, frames = 0, sampleRate = 0;
    double bpm = 0, effectiveBpm = 0, tempo = 1, beat = 0;
    double cuePoint = 0, loopIn = 0, loopOut = 0;
    std::array<double, kHotCues> hotCues{};
    float fader = 1, peak = 0;
};

struct EngineStatus {
    float masterPeak = 0, cuePeak = 0, limiterReductionDb = 0, crossfader = 0;
    float transitionProgress = -1;  // -1 = idle, else 0..1
    float transitionStartsInBeats = -1;  // >= 0 while waiting for the phrase boundary
    bool cueAvailable = false;
    uint32_t cueUnderruns = 0;
    uint64_t recordedFrames = 0, recordDropped = 0;
    double cueDriftRatio = 1.0;
};

class Engine {
public:
    Engine(double sampleRate, int maxBlock, int numDecks = 2);
    ~Engine();
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    double sampleRate() const { return sampleRate_; }
    int numDecks() const { return numDecks_; }
    int maxBlock() const { return maxBlock_; }

    // ---- Audio thread ------------------------------------------------------------------
    // Non-interleaved output, one pointer per device channel.
    void render(float* const* outputs, int numChannels, int frames);
    // Secondary device callback (Topology::SeparateCueDevice only).
    void renderCue(float* const* outputs, int numChannels, int frames);

    // ---- Control thread ----------------------------------------------------------------
    void setOutputLayout(const OutputLayout& layout);
    // Extra delay so both buses line up in the DJ's ears when output paths differ in latency
    // (e.g. master on a Bluetooth speaker, cue on wired headphones).
    void setLatencyCompensation(int masterDelayFrames, int cueDelayFrames);

    void loadTrack(int deck, TrackRef track);
    void unloadTrack(int deck);
    void play(int deck);
    void pause(int deck);
    void togglePlay(int deck);
    void seek(int deck, double frame);
    void cuePress(int deck);
    void cueRelease(int deck);
    void setHotCue(int deck, int index, double frame);
    void triggerHotCue(int deck, int index);
    void clearHotCue(int deck, int index);
    void setBeatLoop(int deck, double beats);
    void setLoop(int deck, double inFrame, double outFrame, bool active);  // restore a saved loop
    void exitLoop(int deck);
    void jogTouch(int deck, bool on);          // hand on / off the platter
    void jogScratch(int deck, double revolutions);
    void jogBend(int deck, double revolutions);
    void setMotorTime(int deck, double seconds);
    void reloop(int deck);
    void scaleLoop(int deck, double factor);
    void beatJump(int deck, double beats);
    void setTempo(int deck, double ratio);
    void setNudge(int deck, double ratio);
    void sync(int deck, bool lock);  // one-shot tempo+phase match; lock keeps it locked
    void unsync(int deck);
    void setQuantize(bool on);

    void setTrim(int deck, float db);
    void setEq(int deck, EqBand band, float db);
    void setFilter(int deck, float knob);
    void setFader(int deck, float value);
    void setCueEnabled(int deck, bool on);
    void setCrossfaderAssign(int deck, XfAssign assign);
    void setEcho(int deck, float wet, double beats, float feedback);
    void setAutoGain(bool on);

    void setCrossfader(float x);       // -1 (A) .. +1 (B)
    void setCrossfaderCurve(float c);  // 0 smooth blend .. 1 sharp cut
    void setMasterGain(float db);
    void setLimiterCeiling(float db);
    void setHeadphoneGain(float db);
    void setCueMix(float mix);         // 0 = cue only, 1 = master only

    // Library preview: plays a track into the headphones only; never reaches the master.
    void previewLoad(TrackRef track, double startFrame);
    void previewPlay();
    void previewStop();
    void setPreviewGain(float db);

    // Automated beginner-friendly transition between two decks over `beats` beats.
    // phraseBeats > 0 waits for the outgoing deck's next phrase boundary (e.g. 16 beats) before
    // the blend begins; the incoming deck is synced and started immediately (still inaudible).
    void startTransition(int fromDeck, int toDeck, double beats, TransitionStyle style, int phraseBeats = 0);
    void cancelTransition();

    // Master recording tap (post-limiter). Drain from a background thread.
    void setRecording(bool on);
    size_t readRecording(float* interleavedStereo, size_t maxFrames);

    DeckStatus deckStatus(int deck) const;
    EngineStatus status() const;

    // Release track memory the audio thread no longer references (call from control thread).
    void collectGarbage();

    // Test hook: number of commands dropped because the queue was full.
    uint32_t droppedCommands() const { return dropped_.load(); }

private:
    enum class Op : uint8_t;
    struct Command;
    struct Strip;
    struct Transition;
    struct DeckAtomics;

    bool send(const Command& c);
    void applyCommands();
    void applyCommand(const Command& c);
    void processBlock(int n);
    void doSync(int deck, bool lock);
    void syncTo(int deck, int leader, bool lock);
    int pickLeader(int forDeck) const;
    void updateSyncLocks(int n);
    void updateTransition(int n);
    void publishStatus();
    float crossfaderGain(XfAssign a, float x) const;

    double sampleRate_;
    int maxBlock_;
    int numDecks_;

    // Audio-thread state.
    std::array<Deck, kMaxDecks> decks_;
    Deck preview_;
    std::vector<std::unique_ptr<Strip>> strips_;
    std::unique_ptr<Transition> transition_;
    std::array<bool, kMaxDecks> syncLock_{};
    std::array<double, kMaxDecks> syncMult_{};
    bool quantize_ = true, autoGain_ = true, recording_ = false;
    OutputLayout layout_;
    SmoothedValue crossfader_, masterGain_, headphoneGain_, cueMix_, previewGain_;
    float xfCurve_ = 0.0f;
    LookaheadLimiter masterLimiter_, cueLimiter_;
    CompensationDelay masterDelay_, cueDelay_;
    PeakMeter masterMeter_, cueMeter_;
    DriftCompensatedFifo cueFifo_;
    StereoRing recordRing_;
    std::vector<float> mL_, mR_, cL_, cR_, tL_, tR_;
    float meterDecay_ = 0.9f;

    // Thread boundary.
    std::unique_ptr<SpscQueue<Command>> commands_;
    std::atomic<uint32_t> dropped_{0};
    std::atomic<uint64_t> appliedGeneration_{0};
    std::unique_ptr<std::array<DeckAtomics, kMaxDecks>> deckAtomics_;
    std::atomic<float> aMasterPeak_{0}, aCuePeak_{0}, aLimiter_{0}, aCrossfader_{0}, aTransition_{-1}, aTransitionWait_{-1};
    std::atomic<bool> aCueAvailable_{false};
    std::atomic<uint64_t> recordedFrames_{0}, recordDropped_{0};
    std::atomic<double> aCueRatio_{1.0};

    // Control-thread state.
    std::mutex controlMutex_;  // serialises control-thread callers; never taken by audio thread
    std::array<TrackRef, kMaxDecks + 1> owned_;
    std::vector<std::pair<uint64_t, TrackRef>> retired_;
    uint64_t generation_ = 0;
};

}  // namespace sbe
