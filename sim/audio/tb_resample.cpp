// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 (Pocket) — the shell's 88.2 -> 48 kHz resampler on a WAV.
//
//   tb_resample <in.wav> <out.wav> [--16m]
//
// Plays a mono 16-bit WAV of the board's sound (tb_ddonpach --wav: 88,200 Hz,
// or 83,333 with --16m) into pocket_audio_resample at the rate the board
// gives it on a 32 MHz clock, and writes what comes out at 48 kHz.
// tools/pocket/audio_check.py holds the result against scipy's resampler.

#include "Vpocket_audio_resample.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

static std::vector<int16_t> read_wav(const char* p) {
    FILE* f = fopen(p, "rb");
    if (!f) { perror(p); exit(1); }
    std::vector<uint8_t> b;
    uint8_t buf[65536]; size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) b.insert(b.end(), buf, buf + n);
    fclose(f);
    for (size_t i = 12; i + 8 <= b.size();) {
        uint32_t len = b[i + 4] | b[i + 5] << 8 | b[i + 6] << 16 | (uint32_t)b[i + 7] << 24;
        if (!memcmp(&b[i], "data", 4)) {
            std::vector<int16_t> s(len / 2);
            memcpy(s.data(), &b[i + 8], len & ~1u);
            return s;
        }
        i += 8 + len + (len & 1);
    }
    fprintf(stderr, "%s: no data chunk\n", p); exit(1);
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s in.wav out.wav [--16m]\n", argv[0]); return 2; }
    bool m16 = argc > 3 && !strcmp(argv[3], "--16m");
    std::vector<int16_t> in = read_wav(argv[1]), out;
    Vpocket_audio_resample* t = new Vpocket_audio_resample;
    t->rate16m = m16; t->rst = 1; t->in_valid = 0; t->in_sample = 0;
    for (int i = 0; i < 8; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
    t->rst = 0;
    // the board's strobe: an accumulator of the chip's rate on 32 MHz
    const uint64_t num = m16 ? 1000000 : 88200, den = m16 ? 384000000 : 32000000;
    uint64_t acc = 0; size_t k = 0;
    while (k < in.size()) {
        acc += num;
        bool strobe = acc >= den;
        if (strobe) acc -= den;
        t->in_valid = strobe;
        if (strobe) t->in_sample = in[k++];
        t->clk = 0; t->eval(); t->clk = 1; t->eval();
        if (t->out_valid) out.push_back((int16_t)t->out_sample);
    }
    FILE* f = fopen(argv[2], "wb");
    auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
    auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
    uint32_t bytes = out.size() * 2;
    fwrite("RIFF", 1, 4, f); u32(36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
    u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16);
    fwrite("data", 1, 4, f); u32(bytes); fwrite(out.data(), 2, out.size(), f);
    fclose(f);
    fprintf(stderr, "%zu samples in, %zu out\n", in.size(), out.size());
    delete t;
    return 0;
}
