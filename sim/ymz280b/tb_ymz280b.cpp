// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 (Pocket): the board's YMZ280B (rtl/cave/Sound.sv) against
// MAME's (ymz280b_mame.h), driven by the same log of what a game told the
// chip (tools/mame_cave_ymz.lua), sample for sample.
//
//   tb_ymz280b <ymz.bin> <log.txt> <outdir> [--16m] [--rom-lat N] [--seconds S]
//              [--on-begin i,j,..] [--against board.wav]
//
// Each access in the log lands on sample floor(t * rate) (rate = the chip's
// clock / 192 as MAME keeps it: 88200 Hz, or 83333 with --16m for gaia and
// theroes, whose board runs at 83333.3 – here only the order counts): MAME's
// chip takes it after its stream is brought up to that sample (and every
// 1/50 s besides, as MAME's sound manager does: run_mame_model), the board's
// as soon as the sample before is begun – while it is being worked on, so
// its writes wait in the chip's queue, as a 68000's would. The board
// runs on a 32 MHz clock, as on clk_cpu; its sample ROM answers --rom-lat
// clocks after a read is taken (default 12).
//
// Writes model.wav and board.wav (mono, 16-bit) to <outdir> and prints the
// comparison: samples equal, the runs that are not (the first few listed),
// status reads that answered differently from MAME, the most clocks a sample
// took against the clocks between samples, and any late sample.
//
// --on-begin holds the data strobe of the listed writes (indices into the
// log's accesses, from 0) to the clock on which the chip begins the next
// sample, as a 68000's write can fall on the whole board. --against compares
// the board's output with another WAV (the whole board's own, say) instead
// of MAME's chip.

#include "Vtb_ymz280b_top.h"
#include "Vtb_ymz280b_top___024root.h"
#include "verilated.h"
#include "ymz_log.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include <sys/stat.h>

int main(int argc, char** argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s ymz.bin log.txt outdir [--16m] [--rom-lat N] [--seconds S]\n", argv[0]); return 2; }
    std::string outdir = argv[3];
    bool clock16m = false;
    int rom_lat = 12;
    double seconds = 0;
    std::set<size_t> on_begin;
    const char* against = nullptr;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--16m")) clock16m = true;
        else if (!strcmp(argv[i], "--on-begin") && i + 1 < argc) {
            for (char* p = argv[++i]; *p; ) {
                on_begin.insert(strtoul(p, &p, 10));
                if (*p == ',') p++;
            }
        }
        else if (!strcmp(argv[i], "--against") && i + 1 < argc) against = argv[++i];
        else if (!strcmp(argv[i], "--rom-lat") && i + 1 < argc) rom_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
    }
    mkdir(outdir.c_str(), 0755);
    std::vector<uint8_t> rom = read_file(argv[1]);
    std::vector<YmzEvent> ev = read_ymz_log(argv[2]);
    double end_t = ymz_log_end(argv[2]);
    if (seconds > 0 && seconds < end_t) end_t = seconds;
    double rate = stream_rate(clock16m ? 16000000.0 : 16934400.0);

    // ---------------------------------------------------------------- MAME
    std::vector<int64_t> sum = run_mame_model(rom, ev, rate, 50, 0, end_t);
    long total = sum.size();
    std::vector<int16_t> model(total);
    for (long i = 0; i < total; i++) model[i] = to16(sum[i]);
    write_wav16((outdir + "/model.wav").c_str(), model, (int)lround(rate));

    // --------------------------------------------------------------- board
    std::vector<uint8_t> rom24(rom);
    rom24.resize(1u << 24, 0);
    Verilated::commandArgs(argc, argv);
    Vtb_ymz280b_top* t = new Vtb_ymz280b_top;
    t->clock = 0; t->reset = 1; t->clock16m = clock16m;
    t->cpu_rd = 0; t->cpu_wr = 0; t->cpu_addr = 0; t->cpu_din = 0;
    t->rom_dout = 0; t->rom_wait_n = 1; t->rom_valid = 0;
    auto cycle = [&]() { t->clock = 0; t->eval(); t->clock = 1; t->eval(); };
    for (int i = 0; i < 8; i++) cycle();
    t->reset = 0;

    std::vector<int16_t> board;
    board.reserve(total);
    long started = 0;              // samples begun
    size_t e = 0;
    int op = 0;                    // 0 idle; write: 1 select, 2 data; read: 3 strobe, 4 take
    bool rom_busy = false; int rom_cnt = 0; uint32_t rom_a = 0;
    long status_reads = 0, status_diff = 0;
    long sample_start = 0, max_clocks = 0, overruns = 0, clk = 0;
    bool busy = false;
    while ((long)board.size() < total) {
        // ---- what the 68000 does this clock, decided on the settled outputs
        t->cpu_rd = 0; t->cpu_wr = 0;
        if (op == 0 && e < ev.size() && sample_at(ev[e].t, rate, 0) <= started)
            op = ev[e].status ? 3 : 1;
        bool held = op == 2 && on_begin.count(e) && !t->will_begin;
        if (op == 1) { t->cpu_wr = 1; t->cpu_addr = 0; t->cpu_din = ev[e].reg; }
        else if (op == 2 && !held) { t->cpu_wr = 1; t->cpu_addr = 1; t->cpu_din = ev[e].data; }
        else if (op == 3) { t->cpu_rd = 1; t->cpu_addr = 1; }
        // ---- the ROM's requests taken at this edge
        bool take = t->rom_rd && t->rom_wait_n;
        uint32_t take_a = t->rom_addr;
        cycle();
        clk++;
        // ---- after the edge
        if (op == 4) {
            status_reads++;
            if ((t->cpu_dout & 0xff) != ev[e].data) {
                if (status_diff < 8)
                    fprintf(stderr, "status at sample %ld: board %02x, MAME %02x\n",
                            sample_at(ev[e].t, rate, 0), t->cpu_dout & 0xff, ev[e].data);
                status_diff++;
            }
        }
        if (held) {}
        else if (op == 2 || op == 4) { op = 0; e++; }
        else if (op == 1 || op == 3) op++;
        t->rom_valid = 0;
        if (rom_busy) {
            if (--rom_cnt <= 0) { t->rom_valid = 1; t->rom_dout = rom24[rom_a & 0xffffff]; rom_busy = false; }
        }
        if (take) { rom_busy = true; rom_cnt = rom_lat; rom_a = take_a; }
        t->rom_wait_n = !rom_busy;
        if (t->audio_valid) {
            if (started > 0) board.push_back((int16_t)t->audio);
            started++;
            sample_start = clk;
            busy = true;
        }
        if (busy && !t->busy) {
            max_clocks = std::max(max_clocks, clk - sample_start);
            busy = false;
        }
        if (t->overrun) overruns++;
    }
    t->final();
    delete t;
    write_wav16((outdir + "/board.wav").c_str(), board, (int)lround(rate));

    // ------------------------------------------------------------ compare
    if (against) {
        std::vector<int16_t> other = read_wav16(against);
        total = std::min<long>(total, other.size());
        model.assign(other.begin(), other.begin() + total);
        printf("against %s\n", against);
    }
    long exact = 0, runs = 0, maxd = 0, maxat = 0, listed = 0, run_start = -1;
    for (long i = 0; i <= total; i++) {
        bool same = i == total || board[i] == model[i];
        if (i < total) {
            long d = labs((long)board[i] - model[i]);
            if (same) exact++;
            if (d > maxd) { maxd = d; maxat = i; }
        }
        if (!same && run_start < 0) run_start = i;
        if (same && run_start >= 0) {
            runs++;
            if (listed++ < 12)
                printf("  differ %ld-%ld (%.4f s, %ld samples)\n", run_start, i - 1, run_start / rate, i - run_start);
            run_start = -1;
        }
    }
    printf("%ld samples (%.1f s at %.1f Hz): %ld equal (%.4f%%), %ld differing in %ld runs, max %ld at %ld (%.4f s)\n",
           total, total / rate, rate, exact, 100.0 * exact / total, total - exact, runs, maxd, maxat, maxat / rate);
    printf("status reads %ld, %ld answered differently from MAME\n", status_reads, status_diff);
    printf("a sample took at most %ld clocks of %.1f; %ld late\n", max_clocks, 32e6 / rate, overruns);
    return 0;
}
