/*
 * Soundboard Engine — C API.
 *
 * The single boundary between the shared C++ audio engine and the platform hosts
 * (Swift on iOS/macOS, Kotlin/JNI on Android). Plain C so it bridges without wrappers.
 *
 * Threading:
 *   - sbe_engine_render / sbe_engine_render_cue: audio threads only (real-time safe).
 *   - everything else: control threads (lock-free hand-off to the audio thread).
 *   - sbe_track_* analysis functions are slow: call them on a background thread.
 */
#ifndef SOUNDBOARD_SBE_H
#define SOUNDBOARD_SBE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sbe_engine sbe_engine;
typedef struct sbe_track sbe_track;

typedef enum {
    SBE_TOPOLOGY_MASTER_ONLY = 0,        /* one stereo output, no private cue */
    SBE_TOPOLOGY_SPLIT_MONO = 1,         /* L = master (mono), R = cue (mono); DJ splitter cable */
    SBE_TOPOLOGY_MULTICHANNEL = 2,       /* master + cue on separate channel pairs of one device */
    SBE_TOPOLOGY_SEPARATE_CUE_DEVICE = 3 /* cue on a second device; call sbe_engine_render_cue */
} sbe_topology;

typedef enum { SBE_XF_THRU = 0, SBE_XF_A = 1, SBE_XF_B = 2 } sbe_xf_assign;
typedef enum { SBE_EQ_LOW = 0, SBE_EQ_MID = 1, SBE_EQ_HIGH = 2 } sbe_eq_band;
typedef enum {
    SBE_TRANSITION_BLEND = 0,
    SBE_TRANSITION_BASS_SWAP = 1,
    SBE_TRANSITION_FILTER_SWEEP = 2,
    SBE_TRANSITION_ECHO_OUT = 3
} sbe_transition_style;

typedef struct {
    double bpm;               /* 0 if unknown */
    double first_beat_frame;
    double tempo_confidence;  /* 0..1 */
    int key_index;            /* 0-11 major C..B, 12-23 minor; -1 unknown */
    char key_name[16];        /* "A minor" */
    char camelot[4];          /* "8A" */
    double loudness_lufs;
    float auto_gain_db;
} sbe_track_analysis;

typedef struct {
    float low, mid, high, peak;
} sbe_waveform_bin;

typedef struct {
    int loaded, playing, loop_active, sync_locked, cue_enabled;
    double position, frames, sample_rate;
    double bpm, effective_bpm, tempo, beat;
    double cue_point, loop_in, loop_out;
    double hot_cues[8]; /* -1 = unset */
    float fader, peak;
    int touched; /* hand on the platter (scratching) */
} sbe_deck_status;

typedef struct {
    float master_peak, cue_peak, limiter_reduction_db, crossfader;
    float transition_progress; /* -1 idle */
    float transition_starts_in_beats; /* >= 0 while waiting for the phrase boundary, else -1 */
    int cue_available;
    uint32_t cue_underruns;
    uint64_t recorded_frames, record_dropped;
    double cue_drift_ratio;
} sbe_engine_status;

/* ---- Engine lifecycle & audio callbacks ---------------------------------------------- */
sbe_engine* sbe_engine_create(double sample_rate, int max_block_frames, int num_decks);
void sbe_engine_destroy(sbe_engine* e);
void sbe_engine_render(sbe_engine* e, float* const* outputs, int num_channels, int frames);
void sbe_engine_render_cue(sbe_engine* e, float* const* outputs, int num_channels, int frames);

/* ---- Routing -------------------------------------------------------------------------- */
void sbe_engine_set_output_layout(sbe_engine* e, sbe_topology topology, int master_left,
                                  int master_right, int cue_left, int cue_right);
void sbe_engine_set_latency_compensation(sbe_engine* e, int master_delay_frames, int cue_delay_frames);

/* ---- Tracks --------------------------------------------------------------------------- */
sbe_track* sbe_track_create(const float* interleaved, int64_t frames, int channels, double sample_rate);
void sbe_track_release(sbe_track* t);
/* Analyse (slow) and store grid + auto-gain in the track. Call before loading. */
void sbe_track_analyze(sbe_track* t, double min_bpm, double target_lufs, sbe_track_analysis* out);
void sbe_track_set_grid(sbe_track* t, double bpm, double first_beat_frame); /* before loading */
void sbe_track_set_auto_gain(sbe_track* t, float db);                       /* before loading */
int sbe_track_waveform(const sbe_track* t, int frames_per_bin, sbe_waveform_bin* out, int max_bins);
int64_t sbe_track_frames(const sbe_track* t);
int sbe_keys_compatible(int key_a, int key_b);

/* ---- Decks ---------------------------------------------------------------------------- */
void sbe_deck_load(sbe_engine* e, int deck, const sbe_track* t); /* engine retains the track */
void sbe_deck_unload(sbe_engine* e, int deck);
void sbe_deck_play(sbe_engine* e, int deck);
void sbe_deck_pause(sbe_engine* e, int deck);
void sbe_deck_toggle(sbe_engine* e, int deck);
void sbe_deck_seek(sbe_engine* e, int deck, double frame);
void sbe_deck_cue_press(sbe_engine* e, int deck);
void sbe_deck_cue_release(sbe_engine* e, int deck);
void sbe_deck_hot_cue_set(sbe_engine* e, int deck, int index, double frame);
void sbe_deck_hot_cue_trigger(sbe_engine* e, int deck, int index);
void sbe_deck_hot_cue_clear(sbe_engine* e, int deck, int index);
void sbe_deck_beat_loop(sbe_engine* e, int deck, double beats);
/* Restores a saved loop: in/out in track frames; active 0 keeps it stored but not looping (reloop starts it). */
void sbe_deck_set_loop(sbe_engine* e, int deck, double in_frame, double out_frame, int active);
void sbe_deck_loop_exit(sbe_engine* e, int deck);
void sbe_deck_reloop(sbe_engine* e, int deck);
void sbe_deck_loop_scale(sbe_engine* e, int deck, double factor);
void sbe_deck_beat_jump(sbe_engine* e, int deck, double beats);
void sbe_deck_set_tempo(sbe_engine* e, int deck, double ratio);
/* Jog wheel / platter. One revolution = 1.8 s of audio (a 33⅓ rpm record).
 * touch: 1 = hand on the record (it follows the hand), 0 = let go (the motor takes over).
 * scratch: move the hand by signed revolutions while touched.
 * bend: turn the jog edge (not touched): a temporary pitch bend that decays.
 * motor_time: 0 = instant start/stop (CDJ); > 0 = turntable spin-up and brake, in seconds. */
void sbe_deck_jog_touch(sbe_engine* e, int deck, int touched);
void sbe_deck_jog_scratch(sbe_engine* e, int deck, double revolutions);
void sbe_deck_jog_bend(sbe_engine* e, int deck, double revolutions);
void sbe_deck_set_motor_time(sbe_engine* e, int deck, double seconds);
void sbe_deck_set_nudge(sbe_engine* e, int deck, double ratio);
void sbe_deck_sync(sbe_engine* e, int deck, int lock);
void sbe_deck_unsync(sbe_engine* e, int deck);
void sbe_engine_set_quantize(sbe_engine* e, int on);

/* ---- Mixer ---------------------------------------------------------------------------- */
void sbe_channel_set_trim(sbe_engine* e, int deck, float db);
void sbe_channel_set_eq(sbe_engine* e, int deck, sbe_eq_band band, float db); /* <= -80 kills */
void sbe_channel_set_filter(sbe_engine* e, int deck, float knob);             /* -1..1 */
void sbe_channel_set_fader(sbe_engine* e, int deck, float value);             /* 0..1 */
void sbe_channel_set_cue(sbe_engine* e, int deck, int on);
void sbe_channel_set_xf_assign(sbe_engine* e, int deck, sbe_xf_assign assign);
void sbe_channel_set_echo(sbe_engine* e, int deck, float wet, double beats, float feedback);
void sbe_engine_set_auto_gain(sbe_engine* e, int on);
void sbe_mixer_set_crossfader(sbe_engine* e, float x);   /* -1 A .. 1 B */
void sbe_mixer_set_crossfader_curve(sbe_engine* e, float c);
void sbe_mixer_set_master_gain(sbe_engine* e, float db);
void sbe_mixer_set_limiter_ceiling(sbe_engine* e, float db);
void sbe_mixer_set_headphone_gain(sbe_engine* e, float db);
void sbe_mixer_set_cue_mix(sbe_engine* e, float mix);    /* 0 cue .. 1 master */

/* ---- Preview, transitions, recording -------------------------------------------------- */
void sbe_preview_load(sbe_engine* e, const sbe_track* t, double start_frame);
void sbe_preview_play(sbe_engine* e);
void sbe_preview_stop(sbe_engine* e);
void sbe_preview_set_gain(sbe_engine* e, float db);
void sbe_transition_start(sbe_engine* e, int from_deck, int to_deck, double beats, sbe_transition_style style);
/* Starts the blend on the outgoing deck's next phrase boundary (phrase_beats, e.g. 16); 0 = now. */
void sbe_transition_start_on_phrase(sbe_engine* e, int from_deck, int to_deck, double beats,
                                    sbe_transition_style style, int phrase_beats);
void sbe_transition_cancel(sbe_engine* e);
void sbe_recording_set(sbe_engine* e, int on);
size_t sbe_recording_read(sbe_engine* e, float* interleaved_stereo, size_t max_frames);

/* ---- Status --------------------------------------------------------------------------- */
void sbe_deck_get_status(const sbe_engine* e, int deck, sbe_deck_status* out);
void sbe_engine_get_status(const sbe_engine* e, sbe_engine_status* out);
void sbe_engine_collect_garbage(sbe_engine* e);

#ifdef __cplusplus
}
#endif
#endif /* SOUNDBOARD_SBE_H */
