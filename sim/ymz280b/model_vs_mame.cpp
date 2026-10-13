// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 (Pocket): MAME's YMZ280B, ported (ymz280b_mame.h), against
// MAME's own -wavwrite of the same run – the check that the port and the way
// it is driven are MAME's, before the board's chip is held against the port.
//
//   model_vs_mame <ymz.bin> <log.txt> <mame.wav> <clock Hz> [--update-hz F]
//                 [--phase P] [--out model.wav] [--against board.wav]
//                 [--true-rate]
//
// <log.txt> is tools/mame_cave_ymz.lua's. Every access is applied at sample
// floor(t * rate + P) (rate = clock / 192, as a whole number), after the stream is brought up
// to it; the sound manager's own updates fall every 1/F s (default 50 Hz).
// --against compares another file of the same log instead of the model –
// tb_ymz280b's board.wav – with MAME's. --true-rate plays the model at the
// chip's clock / 192 unrounded (83333.3 for 16 MHz), as the board runs, to
// hold a whole-board run (tb_ddonpach --wav --ymz-log) against its own log.

#include "ymz280b_mame.h"
#include "ymz_log.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 5) { fprintf(stderr, "usage: %s ymz.bin log.txt mame.wav clock [--update-hz F] [--phase P] [--out f]\n", argv[0]); return 2; }
    double clock = atof(argv[4]);
    double update_hz = 50, phase = 0;
    const char* out_path = nullptr;
    const char* against = nullptr;
    bool true_rate = false;
    for (int i = 5; i < argc; i++) {
        if (!strcmp(argv[i], "--update-hz") && i + 1 < argc) update_hz = atof(argv[++i]);
        else if (!strcmp(argv[i], "--phase") && i + 1 < argc) phase = atof(argv[++i]);
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) out_path = argv[++i];
        else if (!strcmp(argv[i], "--against") && i + 1 < argc) against = argv[++i];
        else if (!strcmp(argv[i], "--true-rate")) true_rate = true;
    }
    std::vector<uint8_t> rom = read_file(argv[1]);
    std::vector<YmzEvent> ev = read_ymz_log(argv[2]);
    std::vector<int16_t> mame = read_wav16(argv[3]);
    double rate = true_rate ? clock / 192.0 : stream_rate(clock);

    std::vector<int64_t> sum = run_mame_model(rom, ev, rate, update_hz, phase, ymz_log_end(argv[2]));
    std::vector<int16_t> model(sum.size());
    for (size_t i = 0; i < sum.size(); i++) model[i] = to16(sum[i]);
    if (out_path) write_wav16(out_path, model, (int)lround(rate));
    if (against) {
        model = read_wav16(against);
        printf("%s against MAME's file\n", against);
    }

    // MAME's file starts when its first buffer is pushed: find the offset
    // that lines the two up best over the first few seconds of sound
    long first = -1;
    for (size_t i = 0; i < model.size(); i++) if (model[i]) { first = i; break; }
    if (first < 0) { printf("the model is silent\n"); return 1; }
    long best_off = 0, best_err = -1;
    for (long off = -4000; off <= 4000; off++) {
        long err = 0;
        for (long i = first; i < first + 20000 && i < (long)model.size(); i++) {
            long j = i + off;
            if (j < 0 || j >= (long)mame.size()) { err += 1 << 16; continue; }
            err += labs((long)model[i] - mame[j]);
        }
        if (best_err < 0 || err < best_err) { best_err = err; best_off = off; }
    }
    long n = 0, exact = 0, off1 = 0, maxd = 0, maxat = 0;
    double se = 0, ss = 0;
    long runs = 0; bool in_run = false;
    for (long i = 0; i < (long)model.size(); i++) {
        long j = i + best_off;
        if (j < 0 || j >= (long)mame.size()) continue;
        long d = labs((long)model[i] - mame[j]);
        n++;
        if (d == 0) exact++; else if (d == 1) off1++;
        if (d > maxd) { maxd = d; maxat = i; }
        if (d > 1 && !in_run) runs++;
        in_run = d > 1;
        se += (double)d * d; ss += (double)mame[j] * mame[j];
    }
    printf("offset %ld samples (MAME's file = model + offset); %ld compared\n", best_off, n);
    printf("exact %ld (%.4f%%), off by one %ld, worse %ld in %ld runs; max %ld at sample %ld (%.4f s)\n",
           exact, 100.0 * exact / n, off1, n - exact - off1, runs, maxd, maxat, maxat / rate);
    printf("error power %.2f dB below the signal\n", 10 * log10(ss / (se > 0 ? se : 1)));
    return 0;
}
