#include "soundboard/sbe.h"

#include <cstring>

#include "analysis.hpp"
#include "engine.hpp"

struct sbe_engine {
    sbe::Engine engine;
    sbe_engine(double sr, int block, int decks) : engine(sr, block, decks) {}
};
struct sbe_track {
    std::shared_ptr<sbe::AudioBuffer> buffer;
};

using sbe::Engine;

extern "C" {

sbe_engine* sbe_engine_create(double sr, int maxBlock, int decks) {
    if (sr <= 0 || maxBlock <= 0) return nullptr;
    return new sbe_engine(sr, maxBlock, decks);
}
void sbe_engine_destroy(sbe_engine* e) { delete e; }
void sbe_engine_render(sbe_engine* e, float* const* o, int nch, int n) { e->engine.render(o, nch, n); }
void sbe_engine_render_cue(sbe_engine* e, float* const* o, int nch, int n) { e->engine.renderCue(o, nch, n); }

void sbe_engine_set_output_layout(sbe_engine* e, sbe_topology t, int ml, int mr, int cl, int cr) {
    sbe::OutputLayout l;
    l.topology = sbe::Topology(int(t));
    l.masterLeft = ml; l.masterRight = mr; l.cueLeft = cl; l.cueRight = cr;
    e->engine.setOutputLayout(l);
}
void sbe_engine_set_latency_compensation(sbe_engine* e, int m, int c) { e->engine.setLatencyCompensation(m, c); }

sbe_track* sbe_track_create(const float* data, int64_t frames, int channels, double sr) {
    if (!data || frames <= 0 || channels < 1 || sr <= 0) return nullptr;
    return new sbe_track{sbe::AudioBuffer::fromInterleaved(data, frames, channels, sr)};
}
void sbe_track_release(sbe_track* t) { delete t; }

void sbe_track_analyze(sbe_track* t, double minBpm, double targetLufs, sbe_track_analysis* out) {
    if (!t) return;
    sbe::TempoOptions opt;
    if (minBpm > 0) opt.minBpm = minBpm;
    const sbe::Analysis a = sbe::analyzeTrack(*t->buffer, opt, targetLufs);
    t->buffer->grid = a.grid;
    t->buffer->autoGainDb = a.autoGainDb;
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    out->bpm = a.grid.bpm;
    out->first_beat_frame = a.grid.firstBeatFrame;
    out->tempo_confidence = a.tempoConfidence;
    out->key_index = a.key.index;
    std::strncpy(out->key_name, a.key.name.c_str(), sizeof(out->key_name) - 1);
    std::strncpy(out->camelot, a.key.camelot.c_str(), sizeof(out->camelot) - 1);
    out->loudness_lufs = a.loudnessLufs;
    out->auto_gain_db = a.autoGainDb;
}
void sbe_track_set_grid(sbe_track* t, double bpm, double first) { if (t) t->buffer->grid = sbe::BeatGrid{bpm, first}; }
void sbe_track_set_auto_gain(sbe_track* t, float db) { if (t) t->buffer->autoGainDb = db; }
int sbe_track_waveform(const sbe_track* t, int fpb, sbe_waveform_bin* out, int maxBins) {
    if (!t) return 0;
    const auto bins = sbe::computeWaveform(t->buffer->samples.data(), t->buffer->frames, t->buffer->sampleRate, fpb);
    const int n = std::min(int(bins.size()), maxBins);
    for (int i = 0; i < n && out; ++i) out[i] = {bins[i].low, bins[i].mid, bins[i].high, bins[i].peak};
    return out ? n : int(bins.size());
}
int64_t sbe_track_frames(const sbe_track* t) { return t ? t->buffer->frames : 0; }
int sbe_keys_compatible(int a, int b) { return sbe::keysCompatible(a, b) ? 1 : 0; }

void sbe_deck_load(sbe_engine* e, int d, const sbe_track* t) { e->engine.loadTrack(d, t ? t->buffer : nullptr); }
void sbe_deck_unload(sbe_engine* e, int d) { e->engine.unloadTrack(d); }
void sbe_deck_play(sbe_engine* e, int d) { e->engine.play(d); }
void sbe_deck_pause(sbe_engine* e, int d) { e->engine.pause(d); }
void sbe_deck_toggle(sbe_engine* e, int d) { e->engine.togglePlay(d); }
void sbe_deck_seek(sbe_engine* e, int d, double f) { e->engine.seek(d, f); }
void sbe_deck_cue_press(sbe_engine* e, int d) { e->engine.cuePress(d); }
void sbe_deck_cue_release(sbe_engine* e, int d) { e->engine.cueRelease(d); }
void sbe_deck_hot_cue_set(sbe_engine* e, int d, int i, double f) { e->engine.setHotCue(d, i, f); }
void sbe_deck_hot_cue_trigger(sbe_engine* e, int d, int i) { e->engine.triggerHotCue(d, i); }
void sbe_deck_hot_cue_clear(sbe_engine* e, int d, int i) { e->engine.clearHotCue(d, i); }
void sbe_deck_beat_loop(sbe_engine* e, int d, double b) { e->engine.setBeatLoop(d, b); }
void sbe_deck_set_loop(sbe_engine* e, int d, double in, double out, int active) { e->engine.setLoop(d, in, out, active != 0); }
void sbe_deck_loop_exit(sbe_engine* e, int d) { e->engine.exitLoop(d); }
void sbe_deck_jog_touch(sbe_engine* e, int d, int on) { e->engine.jogTouch(d, on != 0); }
void sbe_deck_jog_scratch(sbe_engine* e, int d, double rev) { e->engine.jogScratch(d, rev); }
void sbe_deck_jog_bend(sbe_engine* e, int d, double rev) { e->engine.jogBend(d, rev); }
void sbe_deck_set_motor_time(sbe_engine* e, int d, double s) { e->engine.setMotorTime(d, s); }
void sbe_deck_reloop(sbe_engine* e, int d) { e->engine.reloop(d); }
void sbe_deck_loop_scale(sbe_engine* e, int d, double f) { e->engine.scaleLoop(d, f); }
void sbe_deck_beat_jump(sbe_engine* e, int d, double b) { e->engine.beatJump(d, b); }
void sbe_deck_set_tempo(sbe_engine* e, int d, double r) { e->engine.setTempo(d, r); }
void sbe_deck_set_nudge(sbe_engine* e, int d, double r) { e->engine.setNudge(d, r); }
void sbe_deck_sync(sbe_engine* e, int d, int lock) { e->engine.sync(d, lock != 0); }
void sbe_deck_unsync(sbe_engine* e, int d) { e->engine.unsync(d); }
void sbe_engine_set_quantize(sbe_engine* e, int on) { e->engine.setQuantize(on != 0); }

void sbe_channel_set_trim(sbe_engine* e, int d, float db) { e->engine.setTrim(d, db); }
void sbe_channel_set_eq(sbe_engine* e, int d, sbe_eq_band b, float db) { e->engine.setEq(d, sbe::EqBand(int(b)), db); }
void sbe_channel_set_filter(sbe_engine* e, int d, float k) { e->engine.setFilter(d, k); }
void sbe_channel_set_fader(sbe_engine* e, int d, float v) { e->engine.setFader(d, v); }
void sbe_channel_set_cue(sbe_engine* e, int d, int on) { e->engine.setCueEnabled(d, on != 0); }
void sbe_channel_set_xf_assign(sbe_engine* e, int d, sbe_xf_assign a) { e->engine.setCrossfaderAssign(d, sbe::XfAssign(int(a))); }
void sbe_channel_set_echo(sbe_engine* e, int d, float w, double b, float fb) { e->engine.setEcho(d, w, b, fb); }
void sbe_engine_set_auto_gain(sbe_engine* e, int on) { e->engine.setAutoGain(on != 0); }
void sbe_mixer_set_crossfader(sbe_engine* e, float x) { e->engine.setCrossfader(x); }
void sbe_mixer_set_crossfader_curve(sbe_engine* e, float c) { e->engine.setCrossfaderCurve(c); }
void sbe_mixer_set_master_gain(sbe_engine* e, float db) { e->engine.setMasterGain(db); }
void sbe_mixer_set_limiter_ceiling(sbe_engine* e, float db) { e->engine.setLimiterCeiling(db); }
void sbe_mixer_set_headphone_gain(sbe_engine* e, float db) { e->engine.setHeadphoneGain(db); }
void sbe_mixer_set_cue_mix(sbe_engine* e, float m) { e->engine.setCueMix(m); }

void sbe_preview_load(sbe_engine* e, const sbe_track* t, double f) { e->engine.previewLoad(t ? t->buffer : nullptr, f); }
void sbe_preview_play(sbe_engine* e) { e->engine.previewPlay(); }
void sbe_preview_stop(sbe_engine* e) { e->engine.previewStop(); }
void sbe_preview_set_gain(sbe_engine* e, float db) { e->engine.setPreviewGain(db); }
void sbe_transition_start(sbe_engine* e, int from, int to, double beats, sbe_transition_style s) {
    e->engine.startTransition(from, to, beats, sbe::TransitionStyle(int(s)));
}
void sbe_transition_start_on_phrase(sbe_engine* e, int from, int to, double beats, sbe_transition_style s, int phrase) {
    e->engine.startTransition(from, to, beats, sbe::TransitionStyle(int(s)), phrase);
}
void sbe_transition_cancel(sbe_engine* e) { e->engine.cancelTransition(); }
void sbe_recording_set(sbe_engine* e, int on) { e->engine.setRecording(on != 0); }
size_t sbe_recording_read(sbe_engine* e, float* dst, size_t n) { return e->engine.readRecording(dst, n); }

void sbe_deck_get_status(const sbe_engine* e, int d, sbe_deck_status* o) {
    const sbe::DeckStatus s = e->engine.deckStatus(d);
    o->loaded = s.loaded; o->playing = s.playing; o->loop_active = s.loopActive;
    o->sync_locked = s.syncLocked; o->cue_enabled = s.cueEnabled;
    o->position = s.position; o->frames = s.frames; o->sample_rate = s.sampleRate;
    o->bpm = s.bpm; o->effective_bpm = s.effectiveBpm; o->tempo = s.tempo; o->beat = s.beat;
    o->cue_point = s.cuePoint; o->loop_in = s.loopIn; o->loop_out = s.loopOut;
    for (int i = 0; i < 8; ++i) o->hot_cues[i] = s.hotCues[i];
    o->fader = s.fader; o->peak = s.peak;
    o->touched = s.touched;
}
void sbe_engine_get_status(const sbe_engine* e, sbe_engine_status* o) {
    const sbe::EngineStatus s = e->engine.status();
    o->master_peak = s.masterPeak; o->cue_peak = s.cuePeak; o->limiter_reduction_db = s.limiterReductionDb;
    o->crossfader = s.crossfader; o->transition_progress = s.transitionProgress;
    o->transition_starts_in_beats = s.transitionStartsInBeats;
    o->cue_available = s.cueAvailable; o->cue_underruns = s.cueUnderruns;
    o->recorded_frames = s.recordedFrames; o->record_dropped = s.recordDropped;
    o->cue_drift_ratio = s.cueDriftRatio;
}
void sbe_engine_collect_garbage(sbe_engine* e) { e->engine.collectGarbage(); }
int sbe_engine_read_visual(const sbe_engine* e, float* out, int frames) {
    return frames > 0 && out ? int(e->engine.readVisual(out, size_t(frames))) : 0;
}

}  // extern "C"
