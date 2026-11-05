#include "analysis.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <numeric>

#include "dsp.hpp"

namespace sbe {

// ------------------------------------------------------------------------------------------
// FFT (iterative radix-2, in place)
// ------------------------------------------------------------------------------------------
void fft(std::vector<std::complex<float>>& a, bool inverse) {
    const size_t n = a.size();
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double ang = 2 * kPi / double(len) * (inverse ? 1 : -1);
        const std::complex<float> wl(float(std::cos(ang)), float(std::sin(ang)));
        for (size_t i = 0; i < n; i += len) {
            std::complex<float> w(1);
            for (size_t j = 0; j < len / 2; ++j) {
                const auto u = a[i + j], v = a[i + j + len / 2] * w;
                a[i + j] = u + v;
                a[i + j + len / 2] = u - v;
                w *= wl;
            }
        }
    }
    if (inverse) for (auto& x : a) x /= float(n);
}

namespace {

std::vector<float> mixToMono(const float* stereo, int64_t frames) {
    std::vector<float> m(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; ++i) m[i] = 0.5f * (stereo[2 * i] + stereo[2 * i + 1]);
    return m;
}

std::vector<float> hann(int n) {
    std::vector<float> w(n);
    for (int i = 0; i < n; ++i) w[i] = float(0.5 - 0.5 * std::cos(2 * kPi * i / n));
    return w;
}

float interp(const std::vector<float>& v, double x) {
    if (x < 0) return 0.0f;
    const size_t i = size_t(x);
    if (i + 1 >= v.size()) return 0.0f;
    const float t = float(x - double(i));
    return v[i] + (v[i + 1] - v[i]) * t;
}

// Spectral-flux onset strength envelope.
struct OnsetEnvelope {
    std::vector<float> env;
    std::vector<float> low;  // kick-band (< ~150 Hz) flux, used to tell beats from off-beats
    double frameRate = 200;
    double frameOffsetSamples = 0;  // sample time represented by env[0]
    int hop = 0;
};

OnsetEnvelope onsetEnvelope(const std::vector<float>& mono, double sampleRate) {
    constexpr int N = 1024;
    OnsetEnvelope out;
    out.hop = std::max(1, int(std::lround(sampleRate / 200.0)));
    out.frameRate = sampleRate / out.hop;
    // A transient produces its largest flux when it sits ~3/4 of the way into the analysis
    // window (calibrated against synthetic kicks), so that is the time an envelope frame marks.
    out.frameOffsetSamples = 0.75 * N;
    const auto win = hann(N);
    const int maxBin = std::min(N / 2, int(8000.0 / sampleRate * N));
    std::vector<float> prev(N / 2 + 1, 0.0f), cur(N / 2 + 1), prevLin(N / 2 + 1, 0.0f);
    std::vector<std::complex<float>> buf(N);
    const int64_t frames = int64_t(mono.size());
    for (int64_t start = 0; start + N <= frames; start += out.hop) {
        for (int i = 0; i < N; ++i) buf[i] = mono[size_t(start + i)] * win[i];
        fft(buf);
        float flux = 0.0f, lowFlux = 0.0f;
        const int kickBin = std::max(2, int(100.0 / sampleRate * N));
        for (int k = 1; k <= maxBin; ++k) {
            const float mag = std::abs(buf[k]);
            if (k <= kickBin) { lowFlux += std::max(0.0f, mag - prevLin[k]); prevLin[k] = mag; }
            cur[k] = std::log1p(100.0f * mag);
            const float d = cur[k] - prev[k];
            // Emphasise the kick/bass region slightly: it carries the pulse in dance music.
            const float w = k < maxBin / 16 ? 1.5f : 1.0f;
            if (d > 0) flux += d * w;
        }
        std::swap(prev, cur);
        out.env.push_back(flux);
        out.low.push_back(lowFlux);
    }
    if (!out.env.empty()) out.env[0] = 0.0f;
    // Adaptive threshold: subtract a local mean, keep positive part, light smoothing.
    const int w = int(out.frameRate * 0.15);
    std::vector<float> ps(out.env.size() + 1, 0.0f);
    for (size_t i = 0; i < out.env.size(); ++i) ps[i + 1] = ps[i] + out.env[i];
    std::vector<float> e2(out.env.size());
    for (size_t i = 0; i < out.env.size(); ++i) {
        const size_t a = i >= size_t(w) ? i - w : 0, b = std::min(out.env.size(), i + w + 1);
        const float mean = (ps[b] - ps[a]) / float(b - a);
        e2[i] = std::max(0.0f, out.env[i] - mean);
    }
    for (size_t i = 0; i < e2.size(); ++i) {
        const float a = i > 0 ? e2[i - 1] : 0.0f, c = i + 1 < e2.size() ? e2[i + 1] : 0.0f;
        out.env[i] = 0.25f * a + 0.5f * e2[i] + 0.25f * c;
    }
    return out;
}

// Best comb alignment (mean envelope value on a pulse train) for a period, over all phases.
double combScore(const std::vector<float>& env, double period, double phaseStep, double* bestPhase) {
    double best = -1;
    for (double ph = 0; ph < period; ph += phaseStep) {
        double s = 0;
        int count = 0;
        for (double x = ph; x < double(env.size()) - 1; x += period) { s += interp(env, x); ++count; }
        s = count ? s / count : 0;
        if (s > best) { best = s; if (bestPhase) *bestPhase = ph; }
    }
    return best;
}

}  // namespace

BeatGrid detectBeatGrid(const float* stereo, int64_t frames, double sampleRate, const TempoOptions& opt,
                        double* confidence) {
    BeatGrid grid;
    if (frames < int64_t(sampleRate * 4)) return grid;
    const auto mono = mixToMono(stereo, frames);
    const OnsetEnvelope oe = onsetEnvelope(mono, sampleRate);
    const auto& env = oe.env;
    const double fr = oe.frameRate;
    if (env.size() < 400) return grid;

    // Autocorrelation of the onset envelope.
    const int maxLag = int(fr * 60.0 / 30.0) + 2;
    std::vector<float> acf(size_t(maxLag + 1), 0.0f);
    const double mean = std::accumulate(env.begin(), env.end(), 0.0) / double(env.size());
    std::vector<float> z(env.size());
    for (size_t i = 0; i < env.size(); ++i) z[i] = float(env[i] - mean);
    for (int lag = 1; lag <= maxLag; ++lag) {
        double s = 0;
        for (size_t i = size_t(lag); i < z.size(); ++i) s += double(z[i]) * z[i - lag];
        acf[size_t(lag)] = float(s / double(z.size() - lag));
    }

    // Coarse search inside the folding range, scoring the period and its multiples.
    const double lo = opt.minBpm, hi = opt.minBpm * 2.0;
    double bestBpm = 120, bestScore = -1e30;
    for (double bpm = lo; bpm < hi; bpm += 0.1) {
        const double P = 60.0 / bpm * fr;
        double s = 0;
        for (int k = 1; k <= 4; ++k) if (k * P < maxLag) s += interp(acf, k * P) / std::sqrt(double(k));
        s += 0.5 * interp(acf, P / 2.0);
        if (s > bestScore) { bestScore = s; bestBpm = bpm; }
    }

    // Fine search: comb alignment across the whole track gives sub-0.01 BPM resolution.
    double fineBpm = bestBpm, fineScore = -1, finePhase = 0;
    for (double bpm = bestBpm - 0.3; bpm <= bestBpm + 0.3; bpm += 0.01) {
        double ph = 0;
        const double s = combScore(env, 60.0 / bpm * fr, 0.5, &ph);
        if (s > fineScore) { fineScore = s; fineBpm = bpm; finePhase = ph; }
    }
    for (double bpm = fineBpm - 0.012; bpm <= fineBpm + 0.012; bpm += 0.002) {
        double ph = 0;
        const double s = combScore(env, 60.0 / bpm * fr, 0.25, &ph);
        if (s > fineScore) { fineScore = s; fineBpm = bpm; finePhase = ph; }
    }
    if (opt.snapToInteger) {
        const double r = std::round(fineBpm);
        if (std::fabs(r - fineBpm) < 0.06) {
            double ph = 0;
            const double s = combScore(env, 60.0 / r * fr, 0.25, &ph);
            if (s >= 0.985 * fineScore) { fineBpm = r; finePhase = ph; fineScore = s; }
        }
    }
    // Beat vs off-beat: in dance music the off-beat often carries strong bass and hats, so the
    // broadband pulse can lock half a beat early. The beat is where the kick-band energy lands.
    {
        const double P = 60.0 / fineBpm * fr;
        auto lowAt = [&](double ph) {
            double s = 0;
            int c = 0;
            for (double x = ph; x < double(oe.low.size()) - 1; x += P) { s += interp(oe.low, x); ++c; }
            return c ? s / c : 0.0;
        };
        // Quarter offsets too: a half-time grid (folded tempo) can sit on the off-beats.
        double bestPh = finePhase, bestLow = lowAt(finePhase);
        const double base = bestLow;
        for (int k = 1; k < 4; ++k) {
            const double ph = std::fmod(finePhase + k * P / 4, P);
            const double v = lowAt(ph);
            if (v > bestLow && v > 1.15 * base) { bestLow = v; bestPh = ph; }
        }
        finePhase = bestPh;
    }
    // Fold into range (fine search can step just outside it).
    while (fineBpm >= hi) fineBpm /= 2.0;
    while (fineBpm < lo) fineBpm *= 2.0;

    // Confidence: how much the pulse train stands out from the envelope's average level.
    const double envMean = std::max(1e-9, mean);
    if (confidence) *confidence = std::clamp((fineScore / envMean - 1.0) / 4.0, 0.0, 1.0);

    grid.bpm = fineBpm;
    const double beatLen = 60.0 / fineBpm * sampleRate;
    double first = finePhase * oe.hop + oe.frameOffsetSamples;
    first = std::fmod(first, beatLen);
    if (first < 0) first += beatLen;
    grid.firstBeatFrame = first;
    return grid;
}

// ------------------------------------------------------------------------------------------
// Key detection: chromagram correlated against Krumhansl-Kessler key profiles.
// ------------------------------------------------------------------------------------------
KeyResult detectKey(const float* stereo, int64_t frames, double sampleRate) {
    static constexpr std::array<double, 12> kMajor = {6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                                                      2.52, 5.19, 2.39, 3.66, 2.29, 2.88};
    static constexpr std::array<double, 12> kMinor = {6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                                                      2.54, 4.75, 3.98, 2.69, 3.34, 3.17};
    KeyResult res;
    constexpr int N = 8192;
    if (frames < N) return res;
    const auto mono = mixToMono(stereo, frames);
    const auto win = hann(N);
    std::array<double, 12> chroma{};
    std::vector<std::complex<float>> buf(N);
    const int kLo = int(std::ceil(60.0 / sampleRate * N)), kHi = int(2100.0 / sampleRate * N);
    for (int64_t start = 0; start + N <= frames; start += N / 2) {
        for (int i = 0; i < N; ++i) buf[i] = mono[size_t(start + i)] * win[i];
        fft(buf);
        std::array<double, 12> frameChroma{};
        for (int k = kLo; k <= kHi; ++k) {
            const double f = k * sampleRate / N;
            const double pitch = 69.0 + 12.0 * std::log2(f / 440.0);
            const double nearest = std::round(pitch);
            const double dev = std::fabs(pitch - nearest);
            if (dev > 0.35) continue;
            const int pc = ((int(nearest) % 12) + 12) % 12;
            frameChroma[pc] += std::sqrt(double(std::abs(buf[k]))) * (1.0 - dev / 0.35);
        }
        const double sum = std::accumulate(frameChroma.begin(), frameChroma.end(), 0.0);
        if (sum > 1e-6) for (int i = 0; i < 12; ++i) chroma[i] += frameChroma[i] / sum;
    }
    auto pearson = [](const std::array<double, 12>& a, const std::array<double, 12>& b, int rot) {
        double ma = 0, mb = 0;
        for (int i = 0; i < 12; ++i) { ma += a[i]; mb += b[i]; }
        ma /= 12; mb /= 12;
        double num = 0, da = 0, db = 0;
        for (int i = 0; i < 12; ++i) {
            const double x = a[(i + rot) % 12] - ma, y = b[i] - mb;
            num += x * y; da += x * x; db += y * y;
        }
        return num / std::sqrt(std::max(1e-12, da * db));
    };
    double best = -2, second = -2;
    for (int key = 0; key < 24; ++key) {
        const double r = pearson(chroma, key < 12 ? kMajor : kMinor, key % 12);
        if (r > best) { second = best; best = r; res.index = key; }
        else if (r > second) second = r;
    }
    res.confidence = best - second;
    res.name = nameForKey(res.index);
    res.camelot = camelotForKey(res.index);
    return res;
}

std::string nameForKey(int index) {
    static const char* names[12] = {"C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"};
    if (index < 0 || index > 23) return "";
    return std::string(names[index % 12]) + (index < 12 ? " major" : " minor");
}

std::string camelotForKey(int index) {
    if (index < 0 || index > 23) return "";
    const int majorPc = index < 12 ? index : (index % 12 + 3) % 12;
    const int number = ((majorPc * 7) % 12 + 7) % 12 + 1;
    return std::to_string(number) + (index < 12 ? "B" : "A");
}

bool keysCompatible(int a, int b) {
    if (a < 0 || b < 0) return false;
    const std::string ca = camelotForKey(a), cb = camelotForKey(b);
    const int na = std::stoi(ca), nb = std::stoi(cb);
    const char la = ca.back(), lb = cb.back();
    if (na == nb) return true;  // identical or relative major/minor
    const int diff = std::abs(na - nb);
    return la == lb && (diff == 1 || diff == 11);
}

// ------------------------------------------------------------------------------------------
// Loudness (ITU-R BS.1770-4 integrated, gated)
// ------------------------------------------------------------------------------------------
double integratedLoudness(const float* stereo, int64_t frames, double sampleRate) {
    // K-weighting with the parametrisation that reproduces the BS.1770 reference coefficients
    // at 48 kHz exactly, and generalises to any sample rate.
    std::array<Biquad, 2> shelf, hp;
    {
        const double f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196;
        const double K = std::tan(kPi * f0 / sampleRate);
        const double Vh = std::pow(10.0, G / 20.0), Vb = std::pow(Vh, 0.4996667741545416);
        const double a0 = 1.0 + K / Q + K * K;
        Biquad b;
        b.b0 = float((Vh + Vb * K / Q + K * K) / a0);
        b.b1 = float(2.0 * (K * K - Vh) / a0);
        b.b2 = float((Vh - Vb * K / Q + K * K) / a0);
        b.a1 = float(2.0 * (K * K - 1.0) / a0);
        b.a2 = float((1.0 - K / Q + K * K) / a0);
        shelf[0] = shelf[1] = b;
    }
    {
        const double f0 = 38.13547087602444, Q = 0.5003270373238773;
        const double K = std::tan(kPi * f0 / sampleRate);
        const double a0 = 1.0 + K / Q + K * K;
        Biquad b;
        b.b0 = 1.0f; b.b1 = -2.0f; b.b2 = 1.0f;
        b.a1 = float(2.0 * (K * K - 1.0) / a0);
        b.a2 = float((1.0 - K / Q + K * K) / a0);
        hp[0] = hp[1] = b;
    }
    const int step = int(sampleRate * 0.1);  // 100 ms hop, 400 ms blocks
    std::vector<double> stepPower;
    double accum = 0;
    int count = 0;
    for (int64_t i = 0; i < frames; ++i) {
        for (int c = 0; c < 2; ++c) {
            const float y = hp[c].process(shelf[c].process(stereo[2 * i + c]));
            accum += double(y) * y;
        }
        if (++count == step) { stepPower.push_back(accum / step); accum = 0; count = 0; }
    }
    std::vector<double> blocks;
    for (size_t i = 3; i < stepPower.size(); ++i)
        blocks.push_back((stepPower[i] + stepPower[i - 1] + stepPower[i - 2] + stepPower[i - 3]) / 4.0);
    auto lufs = [](double z) { return -0.691 + 10.0 * std::log10(std::max(z, 1e-12)); };
    double sum = 0;
    int n = 0;
    for (double z : blocks) if (lufs(z) > -70.0) { sum += z; ++n; }
    if (n == 0) return -70.0;
    const double rel = lufs(sum / n) - 10.0;
    sum = 0; n = 0;
    for (double z : blocks) if (lufs(z) > -70.0 && lufs(z) > rel) { sum += z; ++n; }
    return n ? lufs(sum / n) : -70.0;
}

// ------------------------------------------------------------------------------------------
// Three-band waveform overview (low / mid / high peaks per bin)
// ------------------------------------------------------------------------------------------
std::vector<WaveformBin> computeWaveform(const float* stereo, int64_t frames, double sampleRate,
                                         int framesPerBin) {
    std::vector<WaveformBin> bins;
    if (framesPerBin <= 0) return bins;
    Biquad lp1, lp2, hp1, hp2, bm1, bm2;
    lp1.design(Biquad::Type::LowPass, sampleRate, 250, 0.7071); lp2 = lp1;
    hp1.design(Biquad::Type::HighPass, sampleRate, 2500, 0.7071); hp2 = hp1;
    bm1.design(Biquad::Type::HighPass, sampleRate, 250, 0.7071);
    bm2.design(Biquad::Type::LowPass, sampleRate, 2500, 0.7071);
    WaveformBin cur;
    int in = 0;
    for (int64_t i = 0; i < frames; ++i) {
        const float x = 0.5f * (stereo[2 * i] + stereo[2 * i + 1]);
        cur.low = std::max(cur.low, std::fabs(lp2.process(lp1.process(x))));
        cur.high = std::max(cur.high, std::fabs(hp2.process(hp1.process(x))));
        cur.mid = std::max(cur.mid, std::fabs(bm2.process(bm1.process(x))));
        cur.peak = std::max(cur.peak, std::fabs(x));
        if (++in == framesPerBin) { bins.push_back(cur); cur = {}; in = 0; }
    }
    if (in > 0) bins.push_back(cur);
    return bins;
}

Analysis analyzeTrack(const AudioBuffer& b, const TempoOptions& opt, double targetLufs) {
    Analysis a;
    a.grid = detectBeatGrid(b.samples.data(), b.frames, b.sampleRate, opt, &a.tempoConfidence);
    a.key = detectKey(b.samples.data(), b.frames, b.sampleRate);
    a.loudnessLufs = integratedLoudness(b.samples.data(), b.frames, b.sampleRate);
    a.autoGainDb = a.loudnessLufs > -69.0 ? float(std::clamp(targetLufs - a.loudnessLufs, -12.0, 6.0)) : 0.0f;
    return a;
}

}  // namespace sbe
