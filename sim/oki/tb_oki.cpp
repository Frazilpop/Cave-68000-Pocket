// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 (Pocket) — DonPachi's sound on its own: rtl/cave/SoundOki.sv
// driven from a log of the 68000's accesses (tools/mame_cave_oki.lua's, or
// the board's own from tb_ddonpach --oki-log).
//
//   tb_oki <log> <set.rom> <out prefix> [--lat N]
//
// Each access is made on the first clk_cpu clock on which the board has
// begun as many of OKI 1's samples as MAME had made by the access's time,
// floor(t * 15984) (an access on the clock a sample is begun lands after
// it, as in MAME); several at one time go on successive clocks. A status read
// is compared with the log's. The samples the samples' ROM serves are the
// image's (its sample region from 0x80080, build_rom.py's donpachi layout),
// --lat clocks after a read is taken (default 12).
//
// Writes PREFIX.0 and PREFIX.1: each chip's samples as the board made them,
// little-endian int32, as tools/pocket/oki_model.py's --out, so
//   cmp PREFIX.0 MODEL.0 && cmp PREFIX.1 MODEL.1
// says whether the board's chips are MAME's. Prints the status reads that
// differ and the samples that came late.

#include "VSoundOki.h"
#include "verilated.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

struct Event { double t; char kind; int which; int data; };

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: tb_oki <log> <set.rom> <out prefix> [--lat N]\n");
        return 2;
    }
    int lat = 12;
    for (int i = 4; i < argc; i++)
        if (!strcmp(argv[i], "--lat") && i + 1 < argc) lat = atoi(argv[++i]);

    std::vector<Event> ev;
    double end_t = 0;
    {
        FILE* f = fopen(argv[1], "r");
        if (!f) { perror(argv[1]); return 1; }
        char line[256];
        while (fgets(line, sizeof line, f)) {
            if (line[0] == '#') {
                double t;
                if (sscanf(line, "# frame %*d %lf", &t) == 1) end_t = t;
                continue;
            }
            Event e{};
            char k;
            unsigned d;
            if (sscanf(line, "%lf %c %d %x", &e.t, &k, &e.which, &d) == 4) {
                e.kind = k; e.data = d;
                ev.push_back(e);
                if (e.t > end_t) end_t = e.t;
            }
        }
        fclose(f);
    }
    std::vector<uint8_t> rom;
    {
        FILE* f = fopen(argv[2], "rb");
        if (!f) { perror(argv[2]); return 1; }
        fseek(f, 0, SEEK_END);
        rom.resize(ftell(f));
        fseek(f, 0, SEEK_SET);
        if (fread(rom.data(), 1, rom.size(), f) != rom.size()) { perror(argv[2]); return 1; }
        fclose(f);
    }
    const size_t SND = 0x80080;

    VerilatedContext ctx;
    VSoundOki* t = new VSoundOki(&ctx);
    auto clock = [&]() { t->clock = 0; t->eval(); t->clock = 1; t->eval(); };

    t->reset = 1; t->io_pause = 0;
    t->io_oki_0_wr = 0; t->io_oki_1_wr = 0; t->io_nmk_wr = 0;
    t->io_rom_wait_n = 1; t->io_rom_valid = 0;
    for (int i = 0; i < 8; i++) clock();
    t->reset = 0;

    // the board's rate, mirrored: OKI 1's sample begun on the clock its
    // accumulator passes 2,000,000 (999 a clock from reset)
    uint32_t acc = 0;
    long begun = 0;
    std::deque<std::pair<long, uint8_t>> rom_q;     // (clock due, byte)
    bool pending = false;
    long clk = 0;
    std::vector<int32_t> out[2];
    long reads = 0, bad_reads = 0, late = 0;
    size_t next = 0;

    auto s20 = [](uint32_t v) { return (int32_t)(v << 12) >> 12; };
    long last_clk = (long)std::ceil(end_t * 32e6) + 4000;
    while (clk < last_clk) {
        // this clock's edge: does it begin a sample?
        bool tick = acc + 999 >= 2000000;
        long begun_after = begun + (tick ? 1 : 0);

        t->io_oki_0_wr = 0; t->io_oki_1_wr = 0; t->io_nmk_wr = 0;
        if (next < ev.size() && (long)std::floor(ev[next].t * 15984.0) <= begun_after) {
            const Event& e = ev[next++];
            if (e.kind == 'W') {
                (e.which ? t->io_oki_1_wr : t->io_oki_0_wr) = 1;
                (e.which ? t->io_oki_1_din : t->io_oki_0_din) = e.data;
            } else if (e.kind == 'N') {
                t->io_nmk_wr = 1; t->io_nmk_addr = e.which; t->io_nmk_din = e.data;
            } else if (e.kind == 'S') {
                t->eval();
                int got = e.which ? t->io_oki_1_dout : t->io_oki_0_dout;
                reads++;
                if (got != e.data) {
                    if (++bad_reads <= 10)
                        printf("  status at %.9f (sample %ld): MAME %02x, the board %02x\n",
                               e.t, begun_after, e.data, got);
                }
            }
        }

        // the ROM: a read taken when rd meets wait_n, the byte --lat clocks later
        t->io_rom_valid = 0;
        if (!rom_q.empty() && rom_q.front().first <= clk) {
            t->io_rom_valid = 1;
            t->io_rom_dout = rom_q.front().second;
            rom_q.pop_front();
            pending = false;
        }
        t->eval();
        if (t->io_rom_rd && t->io_rom_wait_n && !pending) {
            size_t a = SND + t->io_rom_addr;
            rom_q.push_back({clk + lat, a < rom.size() ? rom[a] : 0});
            pending = true;
        }
        clock();
        if (t->io_sample_valid_0) out[0].push_back(s20(t->io_sample_0));
        if (t->io_sample_valid_1) out[1].push_back(s20(t->io_sample_1));
        if (t->io_overrun) late++;

        acc = tick ? acc + 999 - 2000000 : acc + 999;
        begun = begun_after;
        clk++;
    }
    for (int c = 0; c < 2; c++) {
        std::string fn = std::string(argv[3]) + "." + std::to_string(c);
        FILE* f = fopen(fn.c_str(), "wb");
        if (!f) { perror(fn.c_str()); return 1; }
        fwrite(out[c].data(), 4, out[c].size(), f);
        fclose(f);
    }
    printf("%s: %zu + %zu samples to %.3f s; status reads: %ld agree, %ld differ; %ld late\n",
           argv[1], out[0].size(), out[1].size(), clk / 32e6, reads - bad_reads, bad_reads, late);
    delete t;
    return bad_reads ? 1 : 0;
}
