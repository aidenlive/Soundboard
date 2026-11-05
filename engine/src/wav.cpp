#include "wav.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>

namespace sbe {

namespace {
uint32_t u32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24); }
uint16_t u16(const uint8_t* p) { return uint16_t(p[0] | (p[1] << 8)); }
void put32(std::ofstream& f, uint32_t v) { const uint8_t b[4] = {uint8_t(v), uint8_t(v >> 8), uint8_t(v >> 16), uint8_t(v >> 24)}; f.write((const char*)b, 4); }
void put16(std::ofstream& f, uint16_t v) { const uint8_t b[2] = {uint8_t(v), uint8_t(v >> 8)}; f.write((const char*)b, 2); }
bool fail(std::string* e, const char* msg) { if (e) *e = msg; return false; }
}  // namespace

bool readWav(const std::string& path, WavData& out, std::string* error) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return fail(error, "cannot open file");
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (d.size() < 12 || std::memcmp(d.data(), "RIFF", 4) || std::memcmp(d.data() + 8, "WAVE", 4))
        return fail(error, "not a RIFF/WAVE file");
    int format = 0, channels = 0, bits = 0;
    uint32_t rate = 0;
    const uint8_t* pcm = nullptr;
    size_t pcmBytes = 0;
    for (size_t pos = 12; pos + 8 <= d.size();) {
        const uint32_t size = u32(&d[pos + 4]);
        const uint8_t* body = &d[pos + 8];
        const size_t avail = std::min<size_t>(size, d.size() - pos - 8);
        if (!std::memcmp(&d[pos], "fmt ", 4) && avail >= 16) {
            format = u16(body);
            channels = u16(body + 2);
            rate = u32(body + 4);
            bits = u16(body + 14);
            if (format == 0xFFFE && avail >= 26) format = u16(body + 24);  // EXTENSIBLE subformat
        } else if (!std::memcmp(&d[pos], "data", 4)) {
            pcm = body;
            pcmBytes = avail;
        }
        pos += 8 + size + (size & 1);
    }
    if (!pcm || channels <= 0) return fail(error, "missing fmt or data chunk");
    const int bytes = bits / 8;
    if (!((format == 1 && (bits == 16 || bits == 24 || bits == 32)) || (format == 3 && bits == 32)))
        return fail(error, "unsupported sample format");
    const size_t n = pcmBytes / bytes;
    out.channels = channels;
    out.sampleRate = rate;
    out.samples.resize(n - n % channels);
    for (size_t i = 0; i < out.samples.size(); ++i) {
        const uint8_t* p = pcm + i * bytes;
        float v = 0;
        if (format == 3) std::memcpy(&v, p, 4);
        else if (bits == 16) v = int16_t(u16(p)) / 32768.0f;
        else if (bits == 24) v = float(int32_t((p[0] << 8) | (p[1] << 16) | (uint32_t(p[2]) << 24)) >> 8) / 8388608.0f;
        else v = float(int32_t(u32(p)) / 2147483648.0);
        out.samples[i] = v;
    }
    return true;
}

bool writeWav(const std::string& path, const WavData& data, int bits) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    const bool isFloat = bits == 32;
    const int bytes = bits / 8;
    const uint32_t dataBytes = uint32_t(data.samples.size() * bytes);
    const bool extensible = data.channels > 2;
    const uint32_t fmtSize = extensible ? 40 : 16;
    f.write("RIFF", 4);
    put32(f, 4 + 8 + fmtSize + 8 + dataBytes);
    f.write("WAVE", 4);
    f.write("fmt ", 4);
    put32(f, fmtSize);
    put16(f, extensible ? 0xFFFE : (isFloat ? 3 : 1));
    put16(f, uint16_t(data.channels));
    put32(f, uint32_t(data.sampleRate));
    put32(f, uint32_t(data.sampleRate) * data.channels * bytes);
    put16(f, uint16_t(data.channels * bytes));
    put16(f, uint16_t(bits));
    if (extensible) {
        put16(f, 22);
        put16(f, uint16_t(bits));
        put32(f, 0);  // no positional mask: channels are discrete (master pair, cue pair)
        put16(f, isFloat ? 3 : 1);
        const uint8_t guidTail[14] = {0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71};
        f.write((const char*)guidTail, 14);
    }
    f.write("data", 4);
    put32(f, dataBytes);
    for (float s : data.samples) {
        if (isFloat) { f.write((const char*)&s, 4); continue; }
        const float c = std::clamp(s, -1.0f, 1.0f);
        if (bits == 16) put16(f, uint16_t(int16_t(std::lround(c * 32767.0f))));
        else {
            const int32_t v = int32_t(std::lround(c * 8388607.0f));
            const uint8_t b[3] = {uint8_t(v), uint8_t(v >> 8), uint8_t(v >> 16)};
            f.write((const char*)b, 3);
        }
    }
    return bool(f);
}

}  // namespace sbe
