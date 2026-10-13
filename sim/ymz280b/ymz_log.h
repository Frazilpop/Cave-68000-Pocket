// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 (Pocket): what sim/ymz280b's programs share – reading
// tools/mame_cave_ymz.lua's log, 16-bit WAV files, and running the log
// through MAME's chip (ymz280b_mame.h) as MAME brings its stream up to date.

#pragma once
#include "ymz280b_mame.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

struct YmzEvent {
    double  t;          // machine time, s
    bool    status;     // a status read (else a register write)
    uint8_t reg, data;  // the write; for a read, data is what MAME answered
};

static std::vector<uint8_t> read_file(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> v(n);
    if (fread(v.data(), 1, n, f) != (size_t)n) { perror(path); exit(1); }
    fclose(f);
    return v;
}

static std::vector<YmzEvent> read_ymz_log(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) { perror(path); exit(1); }
    std::vector<YmzEvent> ev;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#') continue;
        double t; char k; unsigned a, b;
        if (sscanf(line, "%lf %c %x %x", &t, &k, &a, &b) == 4 && k == 'W')
            ev.push_back({t, false, (uint8_t)a, (uint8_t)b});
        else if (sscanf(line, "%lf %c %x", &t, &k, &a) == 3 && k == 'S')
            ev.push_back({t, true, 0, (uint8_t)a});
    }
    fclose(f);
    return ev;
}

// the last frame line's time: how long the log runs
static double ymz_log_end(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) { perror(path); exit(1); }
    double end = 0;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        int fr; double t;
        if (sscanf(line, "# frame %d %lf", &fr, &t) == 2) end = t;
    }
    fclose(f);
    return end;
}

static std::vector<int16_t> read_wav16(const char* path) {
    std::vector<uint8_t> b = read_file(path);
    size_t p = 12;
    while (p + 8 <= b.size()) {
        uint32_t len = b[p + 4] | b[p + 5] << 8 | b[p + 6] << 16 | (uint32_t)b[p + 7] << 24;
        if (!memcmp(&b[p], "data", 4)) {
            len = std::min<size_t>(len, b.size() - p - 8);
            std::vector<int16_t> s(len / 2);
            memcpy(s.data(), &b[p + 8], len & ~1u);
            return s;
        }
        p += 8 + len + (len & 1);
    }
    fprintf(stderr, "%s: no data chunk\n", path);
    exit(1);
}

static void write_wav16(const char* path, const std::vector<int16_t>& s, int rate) {
    FILE* f = fopen(path, "wb");
    if (!f) { perror(path); exit(1); }
    auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
    auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
    uint32_t bytes = s.size() * 2;
    fwrite("RIFF", 1, 4, f); u32(36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
    u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
    fwrite("data", 1, 4, f); u32(bytes);
    fwrite(s.data(), 2, s.size(), f);
    fclose(f);
}

// the speaker's sum as MAME writes it to the file: over 32768 * 256, times
// 32768, clamped, towards zero
static int16_t to16(int64_t sum) {
    int64_t v = sum / 256;
    return (int16_t)std::clamp<int64_t>(v, -32768, 32767);
}

// MAME's stream rate for a chip clock: clock / 192, which MAME keeps as a
// whole number (83333 Hz for a 16 MHz chip, where the chip's is 83333.3)
static double stream_rate(double clock) {
    return floor(clock / 192.0);
}

// The sample an access at time t lands on: the stream is brought up to
// floor(t * rate + phase) first.
static long sample_at(double t, double rate, double phase) {
    return (long)floor(t * rate + phase);
}

// Run the log through MAME's chip: before each access, and every 1/update_hz
// s, the stream is brought up to date; returns the speaker's sum per sample.
static std::vector<int64_t> run_mame_model(const std::vector<uint8_t>& rom, const std::vector<YmzEvent>& ev,
                                           double rate, double update_hz, double phase, double end_t = 0) {
    uint32_t size = 1;
    while (size < rom.size()) size <<= 1;
    std::vector<uint8_t> padded(rom);
    padded.resize(size, 0);
    ymz280b_mame chip(padded.data(), size);
    if (end_t <= 0) end_t = ev.empty() ? 0 : ev.back().t;
    long total = sample_at(end_t, rate, phase);
    std::vector<int64_t> out(total + 1, 0);
    long cur = 0;
    double next_tick = update_hz > 0 ? 1.0 / update_hz : 1e300;
    size_t i = 0;
    auto bring_to = [&](long n) {
        n = std::min(n, total);
        if (n > cur) { chip.update(n - cur, &out[cur]); cur = n; }
    };
    while (i < ev.size() || next_tick <= end_t) {
        bool tick = next_tick <= end_t && (i >= ev.size() || next_tick < ev[i].t);
        if (tick) {
            bring_to(sample_at(next_tick, rate, phase));
            chip.fire_timers();
            next_tick += 1.0 / update_hz;
            continue;
        }
        const YmzEvent& e = ev[i++];
        if (e.t > end_t) break;
        bring_to(sample_at(e.t, rate, phase));
        if (e.status) chip.read_status();
        else { chip.write(0, e.reg); chip.write(1, e.data); }
        chip.fire_timers();
    }
    bring_to(total);
    out.resize(cur);
    return out;
}
