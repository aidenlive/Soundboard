#include "engine.hpp"

#include <algorithm>
#include <cmath>

namespace sbe {

enum class Engine::Op : uint8_t {
    Layout, Latency, Load, Play, Pause, Toggle, Seek, CuePress, CueRelease, HotSet, HotTrigger,
    HotClear, BeatLoop, SetLoop, ExitLoop, JogTouch, JogScratch, JogBend, MotorTime, Reloop, ScaleLoop, BeatJump, Tempo, Nudge, Sync, Unsync, Quantize,
    Trim, Eq, Filter, Fader, CueEnable, XfAssignOp, Echo, AutoGain, Crossfader, XfCurve, MasterGain,
    Ceiling, HpGain, CueMix, PreviewLoad, PreviewPlay, PreviewStop, PreviewGain, TransitionStart,
    TransitionCancel, Record
};

struct Engine::Command {
    Op op = Op::Play;
    int32_t deck = 0;
    int32_t i = 0;
    double a = 0, b = 0, c = 0;
    const AudioBuffer* track = nullptr;
    uint64_t gen = 0;
    OutputLayout layout;
};

struct Engine::Strip {
    SmoothedValue trim, fader;
    IsolatorEq eq;
    DjFilter filter;
    BeatEcho echo;
    PeakMeter meter;
    float trimDb = 0.0f, faderValue = 1.0f;
    std::array<float, 3> eqDb{0, 0, 0};
    bool cue = false;
    XfAssign assign = XfAssign::Thru;
    double echoBeats = 0.75;

    void prepare(double sr) {
        trim.reset(sr, 15.0, 1.0f);
        fader.reset(sr, 8.0, 1.0f);
        eq.prepare(sr);
        filter.prepare(sr);
        echo.prepare(sr);
    }
    void setFaderValue(float v) {
        faderValue = clampf(v, 0.0f, 1.0f);
        fader.setTarget(faderValue * faderValue);  // musical (square-law) fader taper
    }
    void setFaderGain(float g) {
        g = clampf(g, 0.0f, 1.0f);
        faderValue = std::sqrt(g);
        fader.setTarget(g);
    }
    void setEq(int band, float db) {
        eqDb[band] = db;
        eq.setBandDb(band, db);
    }
};

struct Engine::Transition {
    bool active = false;
    int from = 0, to = 1;
    TransitionStyle style = TransitionStyle::Blend;
    double total = 1, elapsed = 0, beatFrames = 1;
    bool useCrossfader = false, swapped = false, echoCut = false;
    float xfStart = 0, xfEnd = 0, fromGain0 = 1, toGainTarget = 1;
    double waitUntilBeat = -1;  // outgoing deck's beat at which the blend starts
    bool begun = false;
};

struct Engine::DeckAtomics {
    std::atomic<bool> loaded{false}, playing{false}, loopActive{false}, syncLocked{false}, cue{false}, touched{false};
    std::atomic<double> position{0}, frames{0}, sampleRate{0}, bpm{0}, effectiveBpm{0}, tempo{1}, beat{0};
    std::atomic<double> cuePoint{0}, loopIn{0}, loopOut{0};
    std::array<std::atomic<double>, kHotCues> hotCues;
    std::atomic<float> fader{1}, peak{0};
    DeckAtomics() { for (auto& h : hotCues) h.store(-1.0); }
};

namespace {
double wrapHalf(double x) { return x - std::floor(x + 0.5); }  // -> [-0.5, 0.5)
double frac(double x) { return x - std::floor(x); }
}  // namespace

Engine::Engine(double sampleRate, int maxBlock, int numDecks)
    : sampleRate_(sampleRate),
      maxBlock_(std::clamp(maxBlock, 16, 2048)),
      numDecks_(std::clamp(numDecks, 1, kMaxDecks)),
      transition_(std::make_unique<Transition>()),
      commands_(std::make_unique<SpscQueue<Command>>(1024)),
      deckAtomics_(std::make_unique<std::array<DeckAtomics, kMaxDecks>>()) {
    for (auto& d : decks_) d.prepare(sampleRate);
    preview_.prepare(sampleRate);
    for (int i = 0; i < kMaxDecks; ++i) {
        strips_.push_back(std::make_unique<Strip>());
        strips_.back()->prepare(sampleRate);
        syncMult_[i] = 1.0;
    }
    // Default layout for two decks: A/B on the crossfader.
    strips_[0]->assign = XfAssign::A;
    if (numDecks_ > 1) strips_[1]->assign = XfAssign::B;

    crossfader_.reset(sampleRate, 6.0, 0.0f);
    masterGain_.reset(sampleRate, 20.0, 1.0f);
    headphoneGain_.reset(sampleRate, 20.0, 1.0f);
    cueMix_.reset(sampleRate, 20.0, 0.0f);
    previewGain_.reset(sampleRate, 20.0, 1.0f);
    masterLimiter_.prepare(sampleRate);
    cueLimiter_.prepare(sampleRate);
    masterLimiter_.setCeilingDb(-0.3f);
    cueLimiter_.setCeilingDb(-1.0f);
    masterDelay_.prepare(int(sampleRate));  // up to 1 s of compensation
    cueDelay_.prepare(int(sampleRate));
    cueFifo_.prepare(maxBlock_ * 2 + 1024, int(sampleRate), sampleRate);
    recordRing_.prepare(size_t(sampleRate * 8));
    for (auto* v : {&mL_, &mR_, &cL_, &cR_, &tL_, &tR_}) v->assign(size_t(maxBlock_), 0.0f);
    meterDecay_ = float(std::exp(-double(maxBlock_) / (0.3 * sampleRate)));
}

Engine::~Engine() = default;

// ------------------------------------------------------------------------------------------
// Control thread
// ------------------------------------------------------------------------------------------

bool Engine::send(const Command& c) {
    if (!commands_->push(c)) {
        dropped_.fetch_add(1);
        return false;
    }
    return true;
}

#define SBE_SEND(...)                                   \
    do {                                                \
        std::lock_guard<std::mutex> sbeGuard(controlMutex_); \
        Command c;                                      \
        __VA_ARGS__;                                    \
        send(c);                                        \
    } while (0)

void Engine::setOutputLayout(const OutputLayout& l) { SBE_SEND(c.op = Op::Layout; c.layout = l); }
void Engine::setLatencyCompensation(int m, int q) { SBE_SEND(c.op = Op::Latency; c.i = m; c.a = q); }

void Engine::loadTrack(int deck, TrackRef track) {
    if (deck < 0 || deck >= numDecks_) return;
    std::lock_guard<std::mutex> lock(controlMutex_);
    Command c;
    c.op = Op::Load;
    c.deck = deck;
    c.track = track.get();
    c.gen = ++generation_;
    if (!send(c)) return;
    retired_.emplace_back(c.gen, std::move(owned_[deck]));
    owned_[deck] = std::move(track);
}
void Engine::unloadTrack(int deck) { loadTrack(deck, nullptr); }

void Engine::play(int d) { SBE_SEND(c.op = Op::Play; c.deck = d); }
void Engine::pause(int d) { SBE_SEND(c.op = Op::Pause; c.deck = d); }
void Engine::togglePlay(int d) { SBE_SEND(c.op = Op::Toggle; c.deck = d); }
void Engine::seek(int d, double f) { SBE_SEND(c.op = Op::Seek; c.deck = d; c.a = f); }
void Engine::cuePress(int d) { SBE_SEND(c.op = Op::CuePress; c.deck = d); }
void Engine::cueRelease(int d) { SBE_SEND(c.op = Op::CueRelease; c.deck = d); }
void Engine::setHotCue(int d, int i, double f) { SBE_SEND(c.op = Op::HotSet; c.deck = d; c.i = i; c.a = f); }
void Engine::triggerHotCue(int d, int i) { SBE_SEND(c.op = Op::HotTrigger; c.deck = d; c.i = i); }
void Engine::clearHotCue(int d, int i) { SBE_SEND(c.op = Op::HotClear; c.deck = d; c.i = i); }
void Engine::setBeatLoop(int d, double b) { SBE_SEND(c.op = Op::BeatLoop; c.deck = d; c.a = b); }
void Engine::setLoop(int d, double in, double out, bool active) {
    SBE_SEND(c.op = Op::SetLoop; c.deck = d; c.a = in; c.b = out; c.i = active ? 1 : 0);
}
void Engine::jogTouch(int d, bool on) { SBE_SEND(c.op = Op::JogTouch; c.deck = d; c.i = on ? 1 : 0); }
void Engine::jogScratch(int d, double rev) { SBE_SEND(c.op = Op::JogScratch; c.deck = d; c.a = rev); }
void Engine::jogBend(int d, double rev) { SBE_SEND(c.op = Op::JogBend; c.deck = d; c.a = rev); }
void Engine::setMotorTime(int d, double s) { SBE_SEND(c.op = Op::MotorTime; c.deck = d; c.a = s); }
void Engine::exitLoop(int d) { SBE_SEND(c.op = Op::ExitLoop; c.deck = d); }
void Engine::reloop(int d) { SBE_SEND(c.op = Op::Reloop; c.deck = d); }
void Engine::scaleLoop(int d, double f) { SBE_SEND(c.op = Op::ScaleLoop; c.deck = d; c.a = f); }
void Engine::beatJump(int d, double b) { SBE_SEND(c.op = Op::BeatJump; c.deck = d; c.a = b); }
void Engine::setTempo(int d, double r) { SBE_SEND(c.op = Op::Tempo; c.deck = d; c.a = r); }
void Engine::setNudge(int d, double r) { SBE_SEND(c.op = Op::Nudge; c.deck = d; c.a = r); }
void Engine::sync(int d, bool lock) { SBE_SEND(c.op = Op::Sync; c.deck = d; c.i = lock ? 1 : 0); }
void Engine::unsync(int d) { SBE_SEND(c.op = Op::Unsync; c.deck = d); }
void Engine::setQuantize(bool on) { SBE_SEND(c.op = Op::Quantize; c.i = on); }
void Engine::setTrim(int d, float db) { SBE_SEND(c.op = Op::Trim; c.deck = d; c.a = db); }
void Engine::setEq(int d, EqBand b, float db) { SBE_SEND(c.op = Op::Eq; c.deck = d; c.i = int(b); c.a = db); }
void Engine::setFilter(int d, float k) { SBE_SEND(c.op = Op::Filter; c.deck = d; c.a = k); }
void Engine::setFader(int d, float v) { SBE_SEND(c.op = Op::Fader; c.deck = d; c.a = v); }
void Engine::setCueEnabled(int d, bool on) { SBE_SEND(c.op = Op::CueEnable; c.deck = d; c.i = on); }
void Engine::setCrossfaderAssign(int d, XfAssign a) { SBE_SEND(c.op = Op::XfAssignOp; c.deck = d; c.i = int(a)); }
void Engine::setEcho(int d, float wet, double beats, float fb) {
    SBE_SEND(c.op = Op::Echo; c.deck = d; c.a = wet; c.b = beats; c.c = fb);
}
void Engine::setAutoGain(bool on) { SBE_SEND(c.op = Op::AutoGain; c.i = on); }
void Engine::setCrossfader(float x) { SBE_SEND(c.op = Op::Crossfader; c.a = x); }
void Engine::setCrossfaderCurve(float v) { SBE_SEND(c.op = Op::XfCurve; c.a = v); }
void Engine::setMasterGain(float db) { SBE_SEND(c.op = Op::MasterGain; c.a = db); }
void Engine::setLimiterCeiling(float db) { SBE_SEND(c.op = Op::Ceiling; c.a = db); }
void Engine::setHeadphoneGain(float db) { SBE_SEND(c.op = Op::HpGain; c.a = db); }
void Engine::setCueMix(float m) { SBE_SEND(c.op = Op::CueMix; c.a = m); }

void Engine::previewLoad(TrackRef track, double startFrame) {
    std::lock_guard<std::mutex> lock(controlMutex_);
    Command c;
    c.op = Op::PreviewLoad;
    c.track = track.get();
    c.a = startFrame;
    c.gen = ++generation_;
    if (!send(c)) return;
    retired_.emplace_back(c.gen, std::move(owned_[kPreviewSlot]));
    owned_[kPreviewSlot] = std::move(track);
}
void Engine::previewPlay() { SBE_SEND(c.op = Op::PreviewPlay); }
void Engine::previewStop() { SBE_SEND(c.op = Op::PreviewStop); }
void Engine::setPreviewGain(float db) { SBE_SEND(c.op = Op::PreviewGain; c.a = db); }

void Engine::startTransition(int from, int to, double beats, TransitionStyle s, int phraseBeats) {
    SBE_SEND(c.op = Op::TransitionStart; c.deck = from; c.i = to; c.a = beats; c.b = double(int(s)); c.c = phraseBeats);
}
void Engine::cancelTransition() { SBE_SEND(c.op = Op::TransitionCancel); }
void Engine::setRecording(bool on) { SBE_SEND(c.op = Op::Record; c.i = on); }

size_t Engine::readRecording(float* dst, size_t maxFrames) { return recordRing_.readInterleaved(dst, maxFrames); }

void Engine::collectGarbage() {
    std::lock_guard<std::mutex> lock(controlMutex_);
    const uint64_t applied = appliedGeneration_.load(std::memory_order_acquire);
    retired_.erase(std::remove_if(retired_.begin(), retired_.end(),
                                  [applied](const auto& e) { return e.first <= applied; }),
                   retired_.end());
}

DeckStatus Engine::deckStatus(int d) const {
    DeckStatus s;
    if (d < 0 || d >= numDecks_) return s;
    const DeckAtomics& a = (*deckAtomics_)[d];
    constexpr auto r = std::memory_order_relaxed;
    s.loaded = a.loaded.load(r); s.playing = a.playing.load(r); s.loopActive = a.loopActive.load(r);
    s.syncLocked = a.syncLocked.load(r); s.cueEnabled = a.cue.load(r); s.touched = a.touched.load(r);
    s.position = a.position.load(r); s.frames = a.frames.load(r); s.sampleRate = a.sampleRate.load(r);
    s.bpm = a.bpm.load(r); s.effectiveBpm = a.effectiveBpm.load(r); s.tempo = a.tempo.load(r);
    s.beat = a.beat.load(r); s.cuePoint = a.cuePoint.load(r); s.loopIn = a.loopIn.load(r);
    s.loopOut = a.loopOut.load(r);
    for (int i = 0; i < kHotCues; ++i) s.hotCues[i] = a.hotCues[i].load(r);
    s.fader = a.fader.load(r); s.peak = a.peak.load(r);
    return s;
}

EngineStatus Engine::status() const {
    EngineStatus s;
    constexpr auto r = std::memory_order_relaxed;
    s.masterPeak = aMasterPeak_.load(r); s.cuePeak = aCuePeak_.load(r);
    s.limiterReductionDb = aLimiter_.load(r); s.crossfader = aCrossfader_.load(r);
    s.transitionProgress = aTransition_.load(r); s.cueAvailable = aCueAvailable_.load(r);
    s.transitionStartsInBeats = aTransitionWait_.load(r);
    s.cueUnderruns = cueFifo_.underruns(); s.recordedFrames = recordedFrames_.load(r);
    s.recordDropped = recordDropped_.load(r); s.cueDriftRatio = aCueRatio_.load(r);
    return s;
}

// ------------------------------------------------------------------------------------------
// Audio thread
// ------------------------------------------------------------------------------------------

void Engine::applyCommands() {
    Command c;
    while (commands_->pop(c)) applyCommand(c);
}

void Engine::applyCommand(const Command& c) {
    const bool deckOk = c.deck >= 0 && c.deck < numDecks_;
    Deck* dk = deckOk ? &decks_[c.deck] : nullptr;
    Strip* st = deckOk ? strips_[c.deck].get() : nullptr;
    switch (c.op) {
        case Op::Layout:
            layout_ = c.layout;
            aCueAvailable_.store(layout_.topology != Topology::MasterOnly);
            break;
        case Op::Latency:
            masterDelay_.setDelay(c.i);
            cueDelay_.setDelay(int(c.a));
            break;
        case Op::Load:
            if (dk) {
                if (transition_->active && (transition_->from == c.deck || transition_->to == c.deck))
                    transition_->active = false;
                dk->setTrack(c.track);
                syncLock_[c.deck] = false;
            }
            appliedGeneration_.store(c.gen, std::memory_order_release);
            break;
        case Op::PreviewLoad:
            preview_.setTrack(c.track);
            if (c.track) preview_.seek(c.a);
            appliedGeneration_.store(c.gen, std::memory_order_release);
            break;
        case Op::Play: if (dk) dk->play(); break;
        case Op::Pause: if (dk) dk->pause(); break;
        case Op::Toggle: if (dk) dk->togglePlay(); break;
        case Op::Seek: if (dk) dk->seek(c.a); break;
        case Op::CuePress: if (dk) dk->cuePress(quantize_); break;
        case Op::CueRelease: if (dk) dk->cueRelease(); break;
        case Op::HotSet: if (dk) dk->setHotCue(c.i, c.a); break;
        case Op::HotTrigger: if (dk) dk->triggerHotCue(c.i, quantize_); break;
        case Op::HotClear: if (dk) dk->clearHotCue(c.i); break;
        case Op::BeatLoop: if (dk) dk->setBeatLoop(c.a, quantize_); break;
        case Op::SetLoop:
            if (dk) { dk->setLoop(c.a, c.b); if (!c.i) dk->exitLoop(); }
            break;
        case Op::ExitLoop: if (dk) dk->exitLoop(); break;
        case Op::JogTouch: if (dk) dk->touch(c.i != 0); break;
        case Op::JogScratch: if (dk) dk->scratch(c.a); break;
        case Op::JogBend: if (dk) dk->bend(c.a); break;
        case Op::MotorTime: if (dk) dk->setMotorTime(c.a); break;
        case Op::Reloop: if (dk) dk->reloop(); break;
        case Op::ScaleLoop: if (dk) dk->scaleLoop(c.a); break;
        case Op::BeatJump: if (dk) dk->beatJump(c.a); break;
        case Op::Tempo:
            if (dk) { dk->setTempo(c.a); syncLock_[c.deck] = false; dk->setSyncCorrection(1.0); }
            break;
        case Op::Nudge: if (dk) dk->setNudge(c.a); break;
        case Op::Sync: if (dk) doSync(c.deck, c.i != 0); break;
        case Op::Unsync:
            if (dk) { syncLock_[c.deck] = false; dk->setSyncCorrection(1.0); }
            break;
        case Op::Quantize: quantize_ = c.i != 0; break;
        case Op::Trim: if (st) st->trimDb = float(c.a); break;
        case Op::Eq: if (st && c.i >= 0 && c.i < 3) st->setEq(c.i, float(c.a)); break;
        case Op::Filter: if (st) st->filter.setKnob(float(c.a)); break;
        case Op::Fader: if (st) st->setFaderValue(float(c.a)); break;
        case Op::CueEnable: if (st) st->cue = c.i != 0; break;
        case Op::XfAssignOp: if (st) st->assign = XfAssign(std::clamp(c.i, 0, 2)); break;
        case Op::Echo:
            if (st) {
                st->echoBeats = c.b > 0 ? c.b : st->echoBeats;
                st->echo.setFeedback(float(c.c));
                if (c.a > 0) st->echo.setWet(float(c.a)); else st->echo.releaseInput();
            }
            break;
        case Op::AutoGain: autoGain_ = c.i != 0; break;
        case Op::Crossfader: crossfader_.setTarget(clampf(float(c.a), -1, 1)); break;
        case Op::XfCurve: xfCurve_ = clampf(float(c.a), 0, 1); break;
        case Op::MasterGain: masterGain_.setTarget(dbToGain(float(c.a))); break;
        case Op::Ceiling: masterLimiter_.setCeilingDb(float(std::min(0.0, c.a))); break;
        case Op::HpGain: headphoneGain_.setTarget(dbToGain(float(c.a))); break;
        case Op::CueMix: cueMix_.setTarget(clampf(float(c.a), 0, 1)); break;
        case Op::PreviewPlay: preview_.play(); break;
        case Op::PreviewStop: preview_.pause(); break;
        case Op::PreviewGain: previewGain_.setTarget(dbToGain(float(c.a))); break;
        case Op::TransitionStart: {
            const int from = c.deck, to = c.i;
            if (!deckOk || to < 0 || to >= numDecks_ || to == from) break;
            if (!decks_[from].loaded() || !decks_[to].loaded()) break;
            Transition& t = *transition_;
            Strip& sf = *strips_[from];
            Strip& sto = *strips_[to];
            t = Transition{};
            t.active = true;
            t.from = from;
            t.to = to;
            t.style = TransitionStyle(std::clamp(int(c.b), 0, 3));
            const double bpm = decks_[from].effectiveBpm() > 0 ? decks_[from].effectiveBpm() : 120.0;
            t.beatFrames = 60.0 / bpm * sampleRate_;
            t.total = std::max(1.0, c.a) * t.beatFrames;
            t.useCrossfader = sf.assign != XfAssign::Thru && sto.assign != XfAssign::Thru && sf.assign != sto.assign;
            t.xfStart = crossfader_.target();
            t.xfEnd = sto.assign == XfAssign::A ? -1.0f : 1.0f;
            t.fromGain0 = sf.fader.target();
            t.toGainTarget = 1.0f;
            // The incoming deck stays inaudible until the blend begins.
            if (!t.useCrossfader) sto.setFaderGain(0.0f);
            else sto.setFaderGain(1.0f);
            if (t.style == TransitionStyle::BassSwap) sto.setEq(0, -96.0f);
            const int phrase = int(c.c);
            if (phrase > 0 && decks_[from].playing()) {
                const double b = decks_[from].beatPosition();
                t.waitUntilBeat = std::ceil(b / phrase - 1e-9) * phrase;
                if (t.waitUntilBeat - b < 0.05) t.waitUntilBeat += phrase;  // too close: next phrase
            }
            if (!decks_[to].playing()) {
                // Match tempo and phase to the outgoing deck, keep it locked during the blend.
                syncTo(to, from, true);
                decks_[to].play();
            }
            aTransition_.store(0.0f);
            break;
        }
        case Op::TransitionCancel:
            transition_->active = false;
            aTransition_.store(-1.0f);
            aTransitionWait_.store(-1.0f);
            break;
        case Op::Record: recording_ = c.i != 0; break;
    }
}

int Engine::pickLeader(int forDeck) const {
    int fallback = -1;
    for (int i = 0; i < numDecks_; ++i) {
        if (i == forDeck) continue;
        const Deck& d = decks_[i];
        if (!d.loaded() || !d.track()->grid.valid()) continue;
        if (d.playing() && !syncLock_[i]) return i;
        if (fallback < 0 || (d.playing() && !decks_[fallback].playing())) fallback = i;
    }
    return fallback;
}

void Engine::doSync(int deck, bool lock) { syncTo(deck, pickLeader(deck), lock); }

void Engine::syncTo(int deck, int leader, bool lock) {
    Deck& dk = decks_[deck];
    if (!dk.loaded() || !dk.track()->grid.valid()) return;
    syncLock_[deck] = lock;
    if (leader < 0 || leader == deck) return;
    const Deck& L = decks_[leader];
    if (!L.loaded() || !L.track()->grid.valid()) return;
    const double leaderBpm = L.effectiveBpm();
    const double deckBpm = dk.track()->grid.bpm;
    // Allow half/double-time matching (e.g. 87 BPM hip-hop against 174 BPM drum & bass).
    double best = 1.0, bestErr = 1e9;
    for (double m : {0.5, 1.0, 2.0}) {
        const double err = std::fabs(std::log(leaderBpm * m / deckBpm));
        if (err < bestErr) { bestErr = err; best = m; }
    }
    syncMult_[deck] = best;
    dk.setTempo(leaderBpm * best / deckBpm);
    dk.setSyncCorrection(1.0);
    const double e = wrapHalf(frac(L.beatPosition() * best) - frac(dk.beatPosition()));
    if (std::fabs(e) > 1e-4) dk.seek(dk.position() + e * dk.beatLengthFrames());
}

void Engine::updateSyncLocks(int n) {
    (void)n;
    for (int d = 0; d < numDecks_; ++d) {
        Deck& dk = decks_[d];
        if (!syncLock_[d]) continue;
        const int leader = pickLeader(d);
        if (leader < 0 || !dk.playing() || !dk.track()->grid.valid()) { dk.setSyncCorrection(1.0); continue; }
        const Deck& L = decks_[leader];
        const double m = syncMult_[d];
        const double tempo = L.effectiveBpm() * m / dk.track()->grid.bpm;
        if (std::fabs(tempo - dk.tempo()) > 1e-9) dk.setTempo(tempo);
        if (!L.playing()) { dk.setSyncCorrection(1.0); continue; }
        const double e = wrapHalf(frac(L.beatPosition() * m) - frac(dk.beatPosition()));
        if (std::fabs(e) > 0.25) {
            dk.seek(dk.position() + e * dk.beatLengthFrames());
            dk.setSyncCorrection(1.0);
            continue;
        }
        // Phase-locked loop: correct the remaining error over ~1 s, max ±1 % pitch.
        const double beatsPerSec = std::max(0.5, dk.effectiveBpm() / 60.0);
        const double corr = std::clamp(e / beatsPerSec, -0.01, 0.01);
        dk.setSyncCorrection(std::fabs(e) < 0.0005 ? 1.0 : 1.0 + corr);
    }
}

void Engine::updateTransition(int n) {
    Transition& t = *transition_;
    if (!t.active) return;
    if (t.waitUntilBeat >= 0) {
        const double b = decks_[t.from].beatPosition();
        if (b < t.waitUntilBeat) {
            aTransitionWait_.store(float(t.waitUntilBeat - b), std::memory_order_relaxed);
            return;
        }
        t.waitUntilBeat = -1;
    }
    aTransitionWait_.store(-1.0f, std::memory_order_relaxed);
    if (!t.begun) {
        t.begun = true;
        if (t.style == TransitionStyle::EchoOut) {
            Strip& sfe = *strips_[t.from];
            sfe.echoBeats = 0.75;
            sfe.echo.setFeedback(0.6f);
            sfe.echo.setWet(0.7f);
        }
    }
    t.elapsed += n;
    const float p = float(std::min(1.0, t.elapsed / t.total));
    Strip& sf = *strips_[t.from];
    Strip& sto = *strips_[t.to];
    const float halfPi = float(kPi / 2);

    auto fade = [&](float q) {
        if (t.useCrossfader) {
            crossfader_.setTarget(t.xfStart + (t.xfEnd - t.xfStart) * q);
        } else {
            sf.setFaderGain(t.fromGain0 * std::cos(q * halfPi));
            sto.setFaderGain(t.toGainTarget * std::sin(q * halfPi));
        }
    };

    switch (t.style) {
        case TransitionStyle::Blend:
            fade(p);
            break;
        case TransitionStyle::BassSwap:
            fade(p);
            if (p >= 0.5f && !t.swapped) {
                sf.setEq(0, -96.0f);
                sto.setEq(0, 0.0f);
                t.swapped = true;
            }
            break;
        case TransitionStyle::FilterSweep:
            fade(p);
            sf.filter.setKnob(0.85f * p);
            sto.filter.setKnob(-0.85f * (1.0f - p));
            break;
        case TransitionStyle::EchoOut:
            if (!t.echoCut && t.elapsed >= t.beatFrames) {
                fade(1.0f);
                sf.echo.releaseInput();
                t.echoCut = true;
            }
            break;
    }

    aTransition_.store(p, std::memory_order_relaxed);
    if (p >= 1.0f) {
        fade(1.0f);
        decks_[t.from].pause();
        for (int b = 0; b < 3; ++b) { sf.setEq(b, 0.0f); }
        sto.setEq(0, 0.0f);
        sf.filter.setKnob(0.0f);
        sto.filter.setKnob(0.0f);
        syncLock_[t.from] = false;
        syncLock_[t.to] = false;  // incoming deck becomes the new leader
        decks_[t.to].setSyncCorrection(1.0);
        t.active = false;
        aTransition_.store(-1.0f, std::memory_order_relaxed);
    }
}

float Engine::crossfaderGain(XfAssign a, float x) const {
    if (a == XfAssign::Thru) return 1.0f;
    float t = (x + 1.0f) * 0.5f;  // 0 = full A, 1 = full B
    if (a == XfAssign::A) t = 1.0f - t;  // t = how much this side is "towards" itself
    // t: 1 = fully on this side, 0 = fully on the other side.
    const float smooth = std::sin(t * float(kPi / 2));
    const float sharp = clampf(t / 0.04f, 0.0f, 1.0f);
    return smooth + (sharp - smooth) * xfCurve_;
}

void Engine::processBlock(int n) {
    std::fill_n(mL_.data(), n, 0.0f);
    std::fill_n(mR_.data(), n, 0.0f);
    std::fill_n(cL_.data(), n, 0.0f);
    std::fill_n(cR_.data(), n, 0.0f);
    const bool cueOn = layout_.topology != Topology::MasterOnly;
    float* tl = tL_.data();
    float* tr = tR_.data();

    // Crossfader position per sample, shared by all channels.
    float xfStart = crossfader_.current();
    float xf[2048];
    const bool xfStatic = !crossfader_.isSmoothing();
    if (!xfStatic) for (int i = 0; i < n && i < 2048; ++i) xf[i] = crossfader_.next();

    for (int d = 0; d < numDecks_; ++d) {
        Deck& dk = decks_[d];
        Strip& s = *strips_[d];
        if (!dk.loaded()) { s.meter.value *= meterDecay_; continue; }
        dk.render(tl, tr, n);

        float trimDb = s.trimDb;
        if (autoGain_) trimDb += dk.track()->autoGainDb;
        s.trim.setTarget(dbToGain(trimDb));
        for (int i = 0; i < n; ++i) { const float g = s.trim.next(); tl[i] *= g; tr[i] *= g; }
        s.eq.process(tl, tr, n);
        s.filter.process(tl, tr, n);
        s.meter.update(tl, tr, n, meterDecay_);

        if (cueOn && s.cue) {  // pre-fader listen
            for (int i = 0; i < n; ++i) { cL_[i] += tl[i]; cR_[i] += tr[i]; }
        }
        for (int i = 0; i < n; ++i) { const float g = s.fader.next(); tl[i] *= g; tr[i] *= g; }
        s.echo.setTiming(dk.effectiveBpm(), s.echoBeats);
        s.echo.process(tl, tr, n);
        if (xfStatic) {
            const float g = crossfaderGain(s.assign, xfStart);
            for (int i = 0; i < n; ++i) { mL_[i] += tl[i] * g; mR_[i] += tr[i] * g; }
        } else {
            for (int i = 0; i < n; ++i) {
                const float g = crossfaderGain(s.assign, xf[std::min(i, 2047)]);
                mL_[i] += tl[i] * g;
                mR_[i] += tr[i] * g;
            }
        }
    }

    // Library preview → headphones only.
    if (cueOn && preview_.loaded()) {
        preview_.render(tl, tr, n);
        for (int i = 0; i < n; ++i) { const float g = previewGain_.next(); cL_[i] += tl[i] * g; cR_[i] += tr[i] * g; }
    }

    // Master bus.
    for (int i = 0; i < n; ++i) { const float g = masterGain_.next(); mL_[i] *= g; mR_[i] *= g; }
    masterLimiter_.process(mL_.data(), mR_.data(), n);
    masterMeter_.update(mL_.data(), mR_.data(), n, meterDecay_);
    if (recording_) {
        const size_t w = recordRing_.write(mL_.data(), mR_.data(), size_t(n));
        recordedFrames_.fetch_add(w, std::memory_order_relaxed);
        if (w < size_t(n)) recordDropped_.fetch_add(size_t(n) - w, std::memory_order_relaxed);
    }

    // Headphone bus: cue/master blend, own gain and safety limiter (protects ears).
    if (cueOn) {
        for (int i = 0; i < n; ++i) {
            const float m = cueMix_.next();
            const float g = headphoneGain_.next();
            cL_[i] = (cL_[i] * (1.0f - m) + mL_[i] * m) * g;
            cR_[i] = (cR_[i] * (1.0f - m) + mR_[i] * m) * g;
        }
        cueLimiter_.process(cL_.data(), cR_.data(), n);
        cueDelay_.process(cL_.data(), cR_.data(), n);
        cueMeter_.update(cL_.data(), cR_.data(), n, meterDecay_);
    } else {
        cueMeter_.value *= meterDecay_;
    }
    masterDelay_.process(mL_.data(), mR_.data(), n);
    // After the latency-compensation delay: visuals match what the speakers play.
    visualTap_.write(mL_.data(), mR_.data(), n);
}

void Engine::render(float* const* out, int nch, int frames) {
    applyCommands();
    int offset = 0;
    while (offset < frames) {
        const int n = std::min(maxBlock_, frames - offset);
        updateTransition(n);
        updateSyncLocks(n);
        processBlock(n);
        for (int ch = 0; ch < nch; ++ch) std::fill_n(out[ch] + offset, n, 0.0f);
        auto put = [&](int ch, const float* src) {
            if (ch >= 0 && ch < nch) std::copy_n(src, n, out[ch] + offset);
        };
        switch (layout_.topology) {
            case Topology::MasterOnly:
            case Topology::SeparateCueDevice:
                if (nch == 1) {
                    for (int i = 0; i < n; ++i) out[0][offset + i] = 0.5f * (mL_[i] + mR_[i]);
                } else {
                    put(layout_.masterLeft, mL_.data());
                    put(layout_.masterRight, mR_.data());
                }
                if (layout_.topology == Topology::SeparateCueDevice) cueFifo_.push(cL_.data(), cR_.data(), n);
                break;
            case Topology::SplitMono:
                // Mono master on masterLeft, mono cue on cueLeft (e.g. 0 and 1 of a headphone jack,
                // or the headphone port's channels inside an iOS multi-route aggregate).
                for (int i = 0; i < n; ++i) { mL_[i] = 0.5f * (mL_[i] + mR_[i]); cL_[i] = 0.5f * (cL_[i] + cR_[i]); }
                put(layout_.masterLeft, mL_.data());
                put(layout_.cueLeft, cL_.data());
                break;
            case Topology::MultiChannel:
                put(layout_.masterLeft, mL_.data());
                put(layout_.masterRight, mR_.data());
                put(layout_.cueLeft, cL_.data());
                put(layout_.cueRight, cR_.data());
                break;
        }
        offset += n;
    }
    publishStatus();
}

void Engine::renderCue(float* const* out, int nch, int frames) {
    if (nch <= 0) return;
    if (nch == 1) {
        // Mono headphone device: pull stereo in chunks and sum.
        float l[256], r[256];
        int done = 0;
        while (done < frames) {
            const int n = std::min(256, frames - done);
            cueFifo_.pull(l, r, n);
            for (int i = 0; i < n; ++i) out[0][done + i] = 0.5f * (l[i] + r[i]);
            done += n;
        }
    } else {
        cueFifo_.pull(out[0], out[1], frames);
        for (int ch = 2; ch < nch; ++ch) std::fill_n(out[ch], frames, 0.0f);
    }
    aCueRatio_.store(cueFifo_.ratio(), std::memory_order_relaxed);
}

void Engine::publishStatus() {
    constexpr auto r = std::memory_order_relaxed;
    for (int d = 0; d < numDecks_; ++d) {
        const Deck& dk = decks_[d];
        const Strip& s = *strips_[d];
        DeckAtomics& a = (*deckAtomics_)[d];
        a.loaded.store(dk.loaded(), r);
        a.playing.store(dk.playing(), r);
        a.loopActive.store(dk.loopActive(), r);
        a.touched.store(dk.touched(), r);
        a.syncLocked.store(syncLock_[d], r);
        a.cue.store(s.cue, r);
        a.position.store(dk.position(), r);
        a.frames.store(dk.loaded() ? double(dk.track()->frames) : 0.0, r);
        a.sampleRate.store(dk.loaded() ? dk.track()->sampleRate : 0.0, r);
        a.bpm.store(dk.loaded() ? dk.track()->grid.bpm : 0.0, r);
        a.effectiveBpm.store(dk.effectiveBpm(), r);
        a.tempo.store(dk.tempo(), r);
        a.beat.store(dk.beatPosition(), r);
        a.cuePoint.store(dk.cuePoint(), r);
        a.loopIn.store(dk.loopIn(), r);
        a.loopOut.store(dk.loopOut(), r);
        for (int i = 0; i < kHotCues; ++i) a.hotCues[i].store(dk.hotCue(i), r);
        a.fader.store(s.faderValue, r);
        a.peak.store(s.meter.value, r);
    }
    aMasterPeak_.store(masterMeter_.value, r);
    aCuePeak_.store(cueMeter_.value, r);
    aLimiter_.store(masterLimiter_.lastGainReductionDb(), r);
    aCrossfader_.store(crossfader_.current(), r);
}

}  // namespace sbe
