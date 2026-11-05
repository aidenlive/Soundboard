// Android audio host: drives the shared engine from Oboe (AAudio) output streams.
//
// Android facts this is built around (see docs/research/platform-audio.md):
//  * Lowest latency needs PerformanceMode::LowLatency + SharingMode::Exclusive (MMAP) + a data
//    callback; Exclusive may be refused, so we always verify what was actually granted.
//  * setDeviceId() is honoured on AAudio (API 28+). Multichannel USB streams (> 2 channels) are
//    opened with an index channel mask by AAudio, so channel N is physical output N.
//  * Playing to two devices at once (e.g. USB + headset) depends on the audio policy of the
//    specific phone, so a second stream is treated as a capability to probe, not an assumption:
//    if the OS re-routes it (getDeviceId() mismatch), we report failure and fall back.
#include <android/log.h>
#include <jni.h>
#include <oboe/Oboe.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <vector>

#include "soundboard/sbe.h"

#define LOG_TAG "SoundboardHost"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

namespace {

constexpr int kMaxChannels = 8;
constexpr int kMaxFrames = 4096;

class StreamDriver : public oboe::AudioStreamDataCallback, public oboe::AudioStreamErrorCallback {
public:
    StreamDriver(sbe_engine* engine, bool isCue) : engine_(engine), isCue_(isCue) {
        for (auto& ch : planar_) ch.assign(kMaxFrames, 0.0f);
        for (int i = 0; i < kMaxChannels; ++i) ptrs_[i] = planar_[i].data();
    }

    oboe::Result open(int deviceId, int channels, int sampleRate) {
        deviceId_ = deviceId;
        channels_ = std::clamp(channels, 1, kMaxChannels);
        sampleRate_ = sampleRate;
        oboe::AudioStreamBuilder b;
        b.setDirection(oboe::Direction::Output)
            ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
            ->setSharingMode(oboe::SharingMode::Exclusive)
            ->setFormat(oboe::AudioFormat::Float)
            ->setChannelCount(channels_)
            ->setSampleRate(sampleRate_)
            ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
            ->setUsage(oboe::Usage::Media)
            ->setContentType(oboe::ContentType::Music)
            ->setDataCallback(this)
            ->setErrorCallback(this);
        if (deviceId > 0) b.setDeviceId(deviceId);
        oboe::Result r = b.openStream(stream_);
        if (r != oboe::Result::OK) return r;
        // Two-period buffer: the usual low-latency sweet spot; tunable at runtime.
        stream_->setBufferSizeInFrames(stream_->getFramesPerBurst() * 2);
        LOGI("%s stream: device %d (asked %d), %d ch, %d Hz, burst %d, %s, %s", isCue_ ? "cue" : "master",
             stream_->getDeviceId(), deviceId, stream_->getChannelCount(), stream_->getSampleRate(),
             stream_->getFramesPerBurst(),
             stream_->getSharingMode() == oboe::SharingMode::Exclusive ? "exclusive" : "shared",
             stream_->getPerformanceMode() == oboe::PerformanceMode::LowLatency ? "low-latency" : "normal");
        return oboe::Result::OK;
    }

    oboe::Result start() { return stream_ ? stream_->requestStart() : oboe::Result::ErrorNull; }
    void close() {
        if (stream_) { stream_->stop(); stream_->close(); stream_.reset(); }
    }
    // The OS may silently route to a different device; callers must check this.
    int actualDeviceId() const { return stream_ ? stream_->getDeviceId() : 0; }
    int channels() const { return stream_ ? stream_->getChannelCount() : 0; }
    double latencySeconds() const {
        if (!stream_) return 0;
        auto r = stream_->calculateLatencyMillis();
        return r ? r.value() / 1000.0 : stream_->getBufferSizeInFrames() / double(stream_->getSampleRate());
    }
    bool disconnected() const { return disconnected_.load(); }

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* s, void* audio, int32_t frames) override {
        float* out = static_cast<float*>(audio);
        const int nch = s->getChannelCount();
        int done = 0;
        while (done < frames) {
            const int n = std::min(kMaxFrames, frames - done);
            if (isCue_) sbe_engine_render_cue(engine_, ptrs_, nch, n);
            else sbe_engine_render(engine_, ptrs_, nch, n);
            for (int i = 0; i < n; ++i)
                for (int c = 0; c < nch; ++c) out[(done + i) * nch + c] = ptrs_[c][i];
            done += n;
        }
        return oboe::DataCallbackResult::Continue;
    }

    void onErrorAfterClose(oboe::AudioStream*, oboe::Result error) override {
        // Headphones unplugged, USB interface removed, BT dropped: the app re-plans the route.
        LOGW("%s stream closed: %s", isCue_ ? "cue" : "master", oboe::convertToText(error));
        disconnected_.store(true);
    }

private:
    sbe_engine* engine_;
    bool isCue_;
    std::shared_ptr<oboe::AudioStream> stream_;
    std::vector<float> planar_[kMaxChannels];
    float* ptrs_[kMaxChannels];
    int deviceId_ = 0, channels_ = 2, sampleRate_ = 48000;
    std::atomic<bool> disconnected_{false};
};

struct Host {
    sbe_engine* engine = nullptr;
    double sampleRate = 48000;
    std::unique_ptr<StreamDriver> master, cue;
    std::mutex mutex;
};

Host* host(jlong h) { return reinterpret_cast<Host*>(h); }

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL Java_com_soundboard_audio_NativeEngine_nativeCreate(JNIEnv*, jclass, jint sampleRate,
                                                                            jint maxBlock, jint decks) {
    auto* h = new Host();
    h->sampleRate = sampleRate;
    h->engine = sbe_engine_create(sampleRate, maxBlock, decks);
    return reinterpret_cast<jlong>(h);
}

JNIEXPORT void JNICALL Java_com_soundboard_audio_NativeEngine_nativeDestroy(JNIEnv*, jclass, jlong h) {
    Host* x = host(h);
    {
        std::lock_guard<std::mutex> lock(x->mutex);
        if (x->cue) x->cue->close();
        if (x->master) x->master->close();
    }
    sbe_engine_destroy(x->engine);
    delete x;
}

// Returns (topologyActuallyUsed << 8) | status; status 0 = OK, 1 = master failed,
// 2 = second device refused / re-routed by the OS (fell back to master only).
JNIEXPORT jint JNICALL Java_com_soundboard_audio_NativeEngine_nativeStart(JNIEnv*, jclass, jlong h, jint topology,
                                                                         jint masterDevice, jint masterChannels,
                                                                         jint cueDevice) {
    Host* x = host(h);
    std::lock_guard<std::mutex> lock(x->mutex);
    if (x->cue) x->cue->close();
    if (x->master) x->master->close();
    x->cue.reset();
    x->master = std::make_unique<StreamDriver>(x->engine, false);
    if (x->master->open(masterDevice, masterChannels, int(x->sampleRate)) != oboe::Result::OK) return 1;

    int result = 0;
    int topo = topology;
    if (topo == SBE_TOPOLOGY_SEPARATE_CUE_DEVICE) {
        x->cue = std::make_unique<StreamDriver>(x->engine, true);
        const bool opened = x->cue->open(cueDevice, 2, int(x->sampleRate)) == oboe::Result::OK;
        if (!opened || x->cue->actualDeviceId() != cueDevice || x->master->actualDeviceId() == x->cue->actualDeviceId()) {
            LOGW("concurrent cue device refused or re-routed (asked %d, got %d): cue disabled", cueDevice,
                 opened ? x->cue->actualDeviceId() : -1);
            x->cue->close();
            x->cue.reset();
            topo = SBE_TOPOLOGY_MASTER_ONLY;
            result = 2;
        }
    }
    return result | (topo << 8);
}

JNIEXPORT void JNICALL Java_com_soundboard_audio_NativeEngine_nativeApplyLayout(JNIEnv* env, jclass, jlong h,
                                                                               jint topology, jintArray channels,
                                                                               jint masterDelay, jint cueDelay) {
    Host* x = host(h);
    jint c[4] = {0, 1, 2, 3};
    if (channels && env->GetArrayLength(channels) >= 4) env->GetIntArrayRegion(channels, 0, 4, c);
    sbe_engine_set_output_layout(x->engine, sbe_topology(topology), c[0], c[1], c[2], c[3]);
    sbe_engine_set_latency_compensation(x->engine, masterDelay, cueDelay);
    std::lock_guard<std::mutex> lock(x->mutex);
    if (x->master) x->master->start();
    if (x->cue) x->cue->start();
}

JNIEXPORT void JNICALL Java_com_soundboard_audio_NativeEngine_nativeStop(JNIEnv*, jclass, jlong h) {
    Host* x = host(h);
    std::lock_guard<std::mutex> lock(x->mutex);
    if (x->cue) x->cue->close();
    if (x->master) x->master->close();
    x->cue.reset();
    x->master.reset();
}

// [masterLatencyS, cueLatencyS, masterPeak, cuePeak, cueUnderruns, disconnected, masterChannels]
JNIEXPORT jfloatArray JNICALL Java_com_soundboard_audio_NativeEngine_nativeStatus(JNIEnv* env, jclass, jlong h) {
    Host* x = host(h);
    sbe_engine_status s;
    sbe_engine_get_status(x->engine, &s);
    sbe_engine_collect_garbage(x->engine);
    float v[7] = {0, 0, s.master_peak, s.cue_peak, float(s.cue_underruns), 0, 0};
    {
        std::lock_guard<std::mutex> lock(x->mutex);
        if (x->master) { v[0] = float(x->master->latencySeconds()); v[5] = x->master->disconnected(); v[6] = float(x->master->channels()); }
        if (x->cue) { v[1] = float(x->cue->latencySeconds()); v[5] = v[5] || x->cue->disconnected(); }
    }
    jfloatArray out = env->NewFloatArray(7);
    env->SetFloatArrayRegion(out, 0, 7, v);
    return out;
}

// Loads interleaved PCM onto a deck (deck = -1 loads the headphone preview player).
JNIEXPORT void JNICALL Java_com_soundboard_audio_NativeEngine_nativeLoadPcm(JNIEnv* env, jclass, jlong h, jint deck,
                                                                           jfloatArray pcm, jint channels,
                                                                           jint sampleRate, jboolean analyze) {
    Host* x = host(h);
    const jsize n = env->GetArrayLength(pcm);
    jfloat* data = env->GetFloatArrayElements(pcm, nullptr);
    sbe_track* t = sbe_track_create(data, n / std::max(1, int(channels)), channels, sampleRate);
    env->ReleaseFloatArrayElements(pcm, data, JNI_ABORT);
    if (!t) return;
    if (analyze) sbe_track_analyze(t, 0, -10.0, nullptr);
    if (deck >= 0) sbe_deck_load(x->engine, deck, t);
    else sbe_preview_load(x->engine, t, 0);
    sbe_track_release(t);  // the engine keeps its own reference
}

JNIEXPORT void JNICALL Java_com_soundboard_audio_NativeEngine_nativeCommand(JNIEnv*, jclass, jlong h, jint op,
                                                                           jint deck, jfloat value) {
    sbe_engine* e = host(h)->engine;
    switch (op) {
        case 0: sbe_deck_play(e, deck); break;
        case 1: sbe_deck_pause(e, deck); break;
        case 2: sbe_channel_set_cue(e, deck, value > 0.5f); break;
        case 3: sbe_channel_set_fader(e, deck, value); break;
        case 4: sbe_mixer_set_crossfader(e, value); break;
        case 5: sbe_mixer_set_cue_mix(e, value); break;
        case 6: sbe_engine_set_auto_gain(e, value > 0.5f); break;
        case 7: sbe_deck_sync(e, deck, value > 0.5f); break;
        case 8: sbe_mixer_set_headphone_gain(e, value); break;
        case 9: sbe_preview_play(e); break;
        case 10: sbe_preview_stop(e); break;
        default: break;
    }
}

}  // extern "C"
