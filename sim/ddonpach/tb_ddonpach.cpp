// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 (Pocket) — whole-board harness.
//
//   tb_ddonpach <set.rom> <game id> <frames> <outdir> [dump frames, comma list]
//          [--rom-lat N] [--spr-lat N] [--fb-lat N] [--all-frames]
//          [--trace file] [--trace-count N] [--trace-data-only]
//          [--prog file --replay N] [--wav file] [--ymz-log file] [--ymz-trace file]
//          [--press list]
//
// Hosts cave68000 (through sim/ddonpach/cave68000_sim.sv, which adds the
// region offsets and upstream's DDR burst bookkeeping) with behavioural
// memories:
//
//   SDRAM   the .rom image. Five cache ports (program, samples, the three
//           layers): a line read is taken when rd meets wait_n, and after
//           --rom-lat clocks the line's four 16-bit words come back one a
//           clock. Optimistic: no contention, no refresh.
//   sprite  the same image, as upstream's DDR held it: a burst of 16 or 32
//           64-bit words, the first --spr-lat clocks after the request.
//   frame   upstream's DDR pages for the sprite frame buffer: burst reads
//   buffer  after --fb-lat clocks, masked writes taken one beat a clock.
//   EEPROM  64 words, seeded from the image's EEPROM region (as upstream's
//           write-back cache read it: the region's bytes big-endian).
//
// Three clocks in one time base of half 96 MHz periods: clk every period,
// clk_cpu every third (32 MHz, rising with clk, as one PLL gives them),
// clk_vid by an accumulator at 28/96.
//
// Writes frame_NNNNN.ppm (320 x 240, as the board puts it out) for each
// requested frame, and one line per frame to stats.csv. Frames count from 1
// at the first vblank, as MAME's frame notifier does. stats.csv's as_clk is
// the clk_cpu clocks the 68000 held AS that frame: with bus_cycles, what its
// bus cycles cost beyond the shortest. AS_HIST=1 prints how long AS was held,
// cycle by cycle, at the end.
//
// --trace writes the 68000's bus in tools/mame_cave_bus_trace.lua's format:
// one line per bus cycle, at the end of the cycle; interrupt acknowledges
// (FC 7) are left out, as MAME has none on the program bus. With
// --trace-data-only, every access to 000400-0fffff (the program) is left out,
// as the Lua script's data-only mode does.
//
// --prog overlays the image's program region with a file (from 0).
// --replay N is for tools/pocket/cave_dump_loader.py's programs, which copy
// MAME's dump of picture N into the board and then spin at 000500: at the
// first fetch there the harness presses pause (the 68000 halts; the sprite
// frame buffer swaps at every vblank, so the loaded list is drawn and shown
// each frame), lets three whole frames go by, and writes the fourth as
// frame_N.ppm, with the sprite layer on screen in it as sprites_N.bin
// (320 x 240 little-endian u16, priority << 14 | colour << 8 | pen, 0 =
// transparent, as the dump's sprite_bitmap.bin). <frames> is then a limit.
//
// --wav writes the sound, one sample per snd_sample (mono, 16-bit, at the
// chip's clock / 192 as MAME keeps it: 88200 Hz, 83333 on gaia). --ymz-log
// writes what the 68000 told the YMZ280B in tools/mame_cave_ymz.lua's
// format, with each access's time put in the middle of the sample it lands
// on – the next one begun (a write made while one is being worked on waits
// for it, as does one on the very clock a sample begins; '+' marks those) –
// so sim/ymz280b's model can play the board's own run back (model_vs_mame
// --true-rate). stats.csv gains the most clk_cpu clocks a sample took that
// frame (of 362.8) and the samples that came late. --ymz-trace writes one
// line per access, clocks in clk_cpu from reset: "<clock> <sample it lands
// on> <clocks since the last sample begun> W <reg> <data> | S, then '+' (it
// waits), 'b' (on the clock a sample begins) and, for a write, "applied
// <clock>" – the clock the chip took it into its registers.
//
// --press holds inputs down over frame ranges, as tools/mame_cave_screens.lua's
// PRESS does and by the same MAME field names: "400-405:Coin 1,600-605:1
// Player Start". "Pause" (the harness's own, not MAME's) holds the board's
// pause, as the Pocket's menu does. An input pressed for frames A-B is set at the end of frame A
// (where MAME's notifier sets it) and let go at the end of frame B + 1.
//
// Built with -DPOCKET_MEM (sim/ddonpach/build.sh --pocket, binary tb_pocket)
// the harness hosts sim/ddonpach/cave68000_psim.sv instead: the board behind
// its Pocket adapters, on kaneko_sdram and an SDRAM model holding the image
// (loaded here before reset, the EEPROM region also streamed past the board
// as the loader would), and on pocket_psram_rows and a PSRAM model per frame
// buffer chip. --rom-lat, --spr-lat and --fb-lat do nothing there; stats.csv's
// spr_bursts column counts sprite lines, fb_rd_bursts and fb_wr_beats the
// rows read and written. The board is released once both memories are ready,
// and the PSRAMs' measured latencies and the models' protocol violations are
// printed at the end.

#ifdef POCKET_MEM
#ifndef DL_BITS
#define DL_BITS 25      // the dl port's word address, [25:1]: the SDRAM's 64 MB
#endif
#include "Vcave68000_psim.h"
#include "Vcave68000_psim___024root.h"
typedef Vcave68000_psim Top;
#else
#include "Vcave68000_sim.h"
typedef Vcave68000_sim Top;
#endif
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <deque>
#include <set>
#include <algorithm>
#include <sys/stat.h>

int main(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s set.rom game frames outdir [dumps] [--rom-lat N] [--spr-lat N] [--fb-lat N]"
                        " [--all-frames] [--trace file] [--trace-count N] [--trace-data-only]\n", argv[0]);
        return 2;
    }
    const char* rom_path = argv[1];
    int game   = atoi(argv[2]);
    int frames = atoi(argv[3]);
    std::string outdir = argv[4];
    std::set<int> dumps;
    int rom_lat = 10, spr_lat = 12, fb_lat = 12;
    bool all_frames = false;
    const char* trace_path = nullptr;
    long trace_count = 0;
    bool trace_data_only = false;
    const char* prog_path = nullptr;
    int replay = -1;
    const char* wav_path = nullptr;
    const char* ymz_log_path = nullptr;
    const char* ymz_trace_path = nullptr;
    struct Press { int from, to, port, bit; };     // port 0 p1, 1 p2, 2 coin, 3 start, 4 service, 5 pause
    std::vector<Press> presses;
    auto parse_presses = [&](const char* list) -> bool {
        static const struct { const char* name; int port, bit; } fields[] = {
            {"P1 Up", 0, 0}, {"P1 Down", 0, 1}, {"P1 Left", 0, 2}, {"P1 Right", 0, 3},
            {"P1 Button 1", 0, 4}, {"P1 Button 2", 0, 5}, {"P1 Button 3", 0, 6},
            {"P1 Button 4", 0, 7},
            {"P2 Up", 1, 0}, {"P2 Down", 1, 1}, {"P2 Left", 1, 2}, {"P2 Right", 1, 3},
            {"P2 Button 1", 1, 4}, {"P2 Button 2", 1, 5}, {"P2 Button 3", 1, 6},
            {"P2 Button 4", 1, 7},
            {"Coin 1", 2, 0}, {"Coin 2", 2, 1},
            {"1 Player Start", 3, 0}, {"2 Players Start", 3, 1},
            {"Service Mode", 4, 0},
            {"Pause", 5, 0},                    // the Pocket's menu open; not MAME's
        };
        std::string s = list;
        size_t p = 0;
        while (p < s.size()) {
            size_t q = s.find(',', p);
            if (q == std::string::npos) q = s.size();
            std::string item = s.substr(p, q - p);
            p = q + 1;
            int a, b, used = 0;
            if (sscanf(item.c_str(), "%d-%d:%n", &a, &b, &used) < 2 || !used) return false;
            std::string name = item.substr(used);
            bool found = false;
            for (auto& f : fields)
                if (name == f.name) { presses.push_back({a, b, f.port, f.bit}); found = true; }
            if (!found) { fprintf(stderr, "--press: no input called %s\n", name.c_str()); return false; }
        }
        return true;
    };
    for (int i = 5; i < argc; i++) {
        if (!strcmp(argv[i], "--rom-lat") && i + 1 < argc)          rom_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--spr-lat") && i + 1 < argc)     spr_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fb-lat") && i + 1 < argc)      fb_lat  = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--all-frames"))                   all_frames = true;
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc)       trace_path = argv[++i];
        else if (!strcmp(argv[i], "--trace-count") && i + 1 < argc) trace_count = atol(argv[++i]);
        else if (!strcmp(argv[i], "--trace-data-only"))              trace_data_only = true;
        else if (!strcmp(argv[i], "--prog") && i + 1 < argc)        prog_path = argv[++i];
        else if (!strcmp(argv[i], "--replay") && i + 1 < argc)      replay = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--wav") && i + 1 < argc)         wav_path = argv[++i];
        else if (!strcmp(argv[i], "--ymz-log") && i + 1 < argc)     ymz_log_path = argv[++i];
        else if (!strcmp(argv[i], "--ymz-trace") && i + 1 < argc)   ymz_trace_path = argv[++i];
        else if (!strcmp(argv[i], "--press") && i + 1 < argc) {
            if (!parse_presses(argv[++i])) return 2;
        }
        else {
            std::string s = argv[i];
            size_t p = 0;
            while (p < s.size()) {
                size_t q = s.find(',', p);
                if (q == std::string::npos) q = s.size();
                if (q > p) dumps.insert(atoi(s.substr(p, q - p).c_str()));
                p = q + 1;
            }
        }
    }
    mkdir(outdir.c_str(), 0755);

    // -------------------------------------------------------------- memories
    std::vector<uint8_t> rom;
    {
        FILE* f = fopen(rom_path, "rb");
        if (!f) { perror(rom_path); return 1; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        rom.resize(n);
        if (fread(rom.data(), 1, n, f) != (size_t)n) { perror("read"); return 1; }
        fclose(f);
    }
    const size_t image_bytes = rom.size();
    rom.resize(64u << 20, 0);
    if (prog_path) {
        FILE* f = fopen(prog_path, "rb");
        if (!f) { perror(prog_path); return 1; }
        size_t n = fread(rom.data(), 1, 16u << 20, f);
        fclose(f);
        fprintf(stderr, "program region: %zu bytes from %s\n", n, prog_path);
    }
    auto rom16 = [&](uint32_t byte) -> uint16_t {      // little-endian, as SDRAM holds the file
        byte &= (64u << 20) - 2;
        return (uint16_t)rom[byte] | ((uint16_t)rom[byte + 1] << 8);
    };
    auto rom64 = [&](uint32_t byte) -> uint64_t {
        uint64_t v = 0;
        byte &= (64u << 20) - 8;
        for (int k = 7; k >= 0; k--) v = (v << 8) | rom[byte + k];
        return v;
    };
    // upstream's DDR pages 0x121 (four 512 KB pages); the address bits above
    // the pages are the base, the same for every access
    std::vector<uint64_t> fbmem(1u << 18, 0);
    uint16_t ee[64];

    Verilated::commandArgs(argc, argv);
    Top* t = new Top;

    t->game = game;
    t->rst = 1; t->rst_cpu = 1; t->rst_vid = 1; t->rom_loaded = 0;
    t->p1 = 0; t->p2 = 0; t->coin = 0; t->start = 0; t->service = 0; t->pause = 0;
    t->dsw = 0xfffb;
    t->clk = 0; t->clk_cpu = 0; t->clk_vid = 0;
    t->eval();
#ifdef POCKET_MEM
    {
        // word w of the image at the chip's word cave_sdram puts it at
        auto& sd = t->rootp->cave68000_psim__DOT__sdram_dev__DOT__mem;
        for (uint32_t w = 0; w < (32u << 20); w++)
            sd[(((w >> 10) & 3) << 23) | ((w >> 12) << 10) | (w & 0x3ff)] = rom16(2 * w);
    }
    (void)ee;
#else
    {
        uint32_t off = t->eeprom_offset;
        for (int i = 0; i < 64; i++) ee[i] = (uint16_t)(rom[off + 2 * i] << 8 | rom[off + 2 * i + 1]);
    }
#endif

    // ------------------------------------------------------------- clocking
    uint64_t cyc = 0;          // clk periods
    int vacc = 0;
    bool cpu_rose = false, vid_rose = false;
    // One clk period: the falling half, then the rising half. clk_cpu rises
    // with clk every third period and falls half-way through (at the falling
    // half three halves later); clk_vid toggles when its accumulator wraps,
    // in either half, and rises at most once a period.
    auto half = [&](int clk) -> void {
        if (!clk) cpu_rose = vid_rose = false;     // both halves count: a clk_vid edge may fall in either
        int ph = (int)(cyc % 3);
        t->clk = clk;
        if (clk && ph == 0)  { t->clk_cpu = 1; cpu_rose = true; }
        if (!clk && ph == 2) t->clk_cpu = 0;
        vacc += 56;
        if (vacc >= 192) {
            vacc -= 192;
            t->clk_vid = !t->clk_vid;
            if (t->clk_vid) vid_rose = true;
        }
        t->eval();
    };

    // ----------------------------------------------------------- port state
    struct LinePort { bool busy = false; int cnt = 0; uint32_t addr = 0; int beat = 0; };
    LinePort lp[5];            // 0 program, 1 samples, 2-4 layers
    struct BurstPort { bool busy = false; int cnt = 0; uint32_t addr = 0; int len = 0, beat = 0; };
    BurstPort spr, fbr;
    uint32_t fbw_base = 0;
    struct { bool busy = false; bool rd = false; uint32_t a = 0; } eep;

#ifdef POCKET_MEM
    // power-on: the memories come up (the SDRAM's init, the PSRAMs' power-up
    // and calibration), then the whole image streams past the board as
    // pocket_rom_loader sends it: every word in order, one clock on and one
    // off, at the word address the dl port carries (DL_BITS of it, as the
    // loader drives the port). The SDRAM model already holds the image; the
    // stream is for the EEPROM's seed, which must take the words at its
    // region and no others.
    t->dl_wr = 0;
    {
        uint64_t n = 0;
        while (!(t->sdram_ready && t->psram_ready)) {
            half(0); half(1); cyc++;
            if (++n > 4000000) { fprintf(stderr, "the memories never came up\n"); return 1; }
        }
        fprintf(stderr, "memories ready after %llu clocks; PSRAM latencies chip 0 rd %d (phase %d) wr %d, "
                "chip 1 rd %d (phase %d) wr %d%s\n",
                (unsigned long long)n, t->psram_lats & 7, (t->psram_lats >> 3) & 1, (t->psram_lats >> 4) & 7,
                (t->psram_lats >> 7) & 7, (t->psram_lats >> 10) & 1, (t->psram_lats >> 11) & 7,
                t->psram_cal_fail ? " (CALIBRATION FAILED)" : "");
        const uint32_t words = (uint32_t)(image_bytes / 2);
        for (uint32_t w = 0; w < words; w++) {
            t->dl_wr = 1; t->dl_addr = w & ((1u << DL_BITS) - 1); t->dl_data = rom16(2 * w);
            half(0); half(1); cyc++;
            t->dl_wr = 0;
            half(0); half(1); cyc++;
            if ((w & 0xfffff) == 0xfffff || w + 1 == words)
                fprintf(stderr, "loaded %u of %u words\n", w + 1, words);
        }
    }
#else
    t->prog_wait_n = 1; t->snd_wait_n = 1; t->tile_wait_n = 7;
    t->spr_wait_n = 1; t->fb_wait_n = 1; t->fbr_wait_n = 1; t->ee_wait_n = 1;
#endif

    // power-on: reset held a while with the image in place
    for (int i = 0; i < 64; i++) { half(0); half(1); cyc++; }
    t->rom_loaded = 1;
    for (int i = 0; i < 64; i++) { half(0); half(1); cyc++; }
    t->rst = 0; t->rst_cpu = 0; t->rst_vid = 0;

    // ------------------------------------------------------------- video
    std::vector<uint8_t> img(320 * 240 * 3, 0);
    int x = 0, y = 0, frame = 1;
    int prev_hb = 1, prev_vb = 1;
    FILE* stats = fopen((outdir + "/stats.csv").c_str(), "w");
    fprintf(stats, "frame,cycles,bus_cycles,max_wait,max_wait_addr,irqs,swaps,spr_bursts,fb_rd_bursts,fb_wr_beats,snd_max_clocks,snd_late,as_clk");
#ifdef POCKET_MEM
    fprintf(stats, ",draw_clk,fb_rd_wait,wait_prog,wait_snd,wait_l0,wait_l1,wait_l2,wait_spr0,wait_spr1");
#endif
    fprintf(stats, "\n");

    // ------------------------------------------------------------- sound
    // the board's true rate for the log's times; MAME's whole one in the WAV
    const double snd_rate = game == 6 ? 16000000.0 / 192.0 : 88200.0;
    std::vector<int16_t> wav;
    FILE* ymz_log = ymz_log_path ? fopen(ymz_log_path, "w") : nullptr;
    if (ymz_log) fprintf(ymz_log, "# the board, game %d\n", game);
    long snd_started = 0;               // samples begun
    uint64_t snd_begin = 0, snd_max_f = 0, snd_late_f = 0, snd_late = 0;
    bool snd_busy_prev = false, ymz_wr_prev = false, ymz_rd_prev = false;
    bool ymz_read_pending = false; long ymz_read_at = 0; bool ymz_read_mid = false;
    uint8_t ymz_reg = 0;
    FILE* ymz_trace = ymz_trace_path ? fopen(ymz_trace_path, "w") : nullptr;
    std::deque<std::string> ymz_queued;      // the writes in the chip's queue, as traced
    uint64_t clk_cpu_n = 0;

    // ------------------------------------------------------------- monitors
    FILE* trace = trace_path ? fopen(trace_path, "w") : nullptr;
    long traced = 0;
    bool as_prev = false, have_rec = false;
    uint32_t rec_a = 0, rec_d = 0, rec_m = 0; bool rec_rd = false, rec_iack = false;
    uint64_t as_start = 0, max_wait = 0; uint32_t max_wait_addr = 0; bool waiting = false;
    uint64_t bus_f = 0, irq_f = 0, swap_f = 0, sprb_f = 0, fbr_f = 0, fbw_f = 0;
    std::vector<uint64_t> as_hist(64, 0);       // AS held, clk_cpu clocks, by length
    uint64_t as_clk_f = 0;                      // AS held this frame, clk_cpu clocks
    bool swap_prev = false;
#ifdef POCKET_MEM
    uint16_t rows_w_prev = t->fb_rows_written, rows_r_prev = t->fb_rows_read;
    uint8_t rom_req_prev = 0;
    uint16_t rows_seen = rows_w_prev;
    uint64_t swap_at = 0, draw_end = 0, draw_max_f = 0, draw_max = 0;
    uint64_t req_at[7] = {0}, req_max_f[7] = {0}, req_max[7] = {0};
    std::vector<uint64_t> lat_hist(128, 0);     // the layers' line reads, by clocks
#endif
    int loaded_frame = -1;       // --replay: the frame the loader finished in
    bool replay_done = false;

    while (frame <= frames && !replay_done) {
        // ---- the falling half: the board settles on this period's inputs
        half(0);

#ifndef POCKET_MEM
        // ---- requests taken at the coming edge
        {
            bool rd[5] = { (bool)t->prog_rd, (bool)t->snd_rd,
                           (bool)(t->tile_rd & 1), (bool)(t->tile_rd & 2), (bool)(t->tile_rd & 4) };
            uint32_t ad[5] = { t->prog_addr, t->snd_addr, t->tile_addr[0], t->tile_addr[1], t->tile_addr[2] };
            for (int p = 0; p < 5; p++)
                if (rd[p] && !lp[p].busy) { lp[p].busy = true; lp[p].cnt = rom_lat; lp[p].addr = ad[p] & ~7u; lp[p].beat = 0; }
        }
        if (t->spr_rd && t->spr_wait_n) {
            spr.busy = true; spr.cnt = spr_lat; spr.addr = t->spr_addr; spr.len = t->spr_len; spr.beat = 0;
            sprb_f++;
        }
        if (t->fbr_rd && t->fbr_wait_n) {
            fbr.busy = true; fbr.cnt = fb_lat; fbr.addr = t->fbr_addr; fbr.len = 16; fbr.beat = 0;
            fbr_f++;
        }
        if (t->fb_wr && t->fb_wait_n) {
            if (t->fb_beat == 0) fbw_base = t->fb_addr;
            uint32_t w = ((fbw_base >> 3) + t->fb_beat) & ((1u << 18) - 1);
            uint64_t v = fbmem[w], d = t->fb_din;
            for (int k = 0; k < 8; k++)
                if ((t->fb_mask >> k) & 1) {
                    uint64_t m = 0xffull << (8 * k);
                    v = (v & ~m) | (d & m);
                }
            fbmem[w] = v;
            fbw_f++;
        }
        if ((t->ee_rd || t->ee_wr) && !eep.busy) {
            uint32_t a = (t->ee_addr >> 1) & 63;
            if (t->ee_wr) ee[a] = t->ee_din;
            eep.busy = true; eep.rd = t->ee_rd; eep.a = a;
        }

#endif
        // ---- the rising half
        half(1);
        cyc++;

#ifndef POCKET_MEM
        // ---- the memories answer for the next period
        {
            uint16_t dout[5] = {0}; bool valid[5] = {false};
            for (int p = 0; p < 5; p++) {
                LinePort& P = lp[p];
                if (!P.busy) continue;
                if (P.cnt > 0) { P.cnt--; continue; }
                dout[p] = rom16(P.addr + 2 * P.beat); valid[p] = true;
                if (++P.beat == 4) P.busy = false;
            }
            t->prog_valid = valid[0]; t->prog_dout = dout[0]; t->prog_wait_n = !lp[0].busy;
            t->snd_valid  = valid[1]; t->snd_dout  = dout[1]; t->snd_wait_n  = !lp[1].busy;
            t->tile_valid = valid[2] | valid[3] << 1 | valid[4] << 2;
            t->tile_dout  = (uint64_t)dout[2] | (uint64_t)dout[3] << 16 | (uint64_t)dout[4] << 32;
            t->tile_wait_n = !lp[2].busy | !lp[3].busy << 1 | !lp[4].busy << 2;
        }
        t->spr_valid = 0;
        if (spr.busy) {
            if (spr.cnt > 0) spr.cnt--;
            else {
                t->spr_dout = rom64(spr.addr + 8 * spr.beat); t->spr_valid = 1;
                if (++spr.beat == spr.len) spr.busy = false;
            }
        }
        t->spr_wait_n = !spr.busy;
        t->fbr_valid = 0;
        if (fbr.busy) {
            if (fbr.cnt > 0) fbr.cnt--;
            else {
                t->fbr_dout = fbmem[((fbr.addr >> 3) + fbr.beat) & ((1u << 18) - 1)]; t->fbr_valid = 1;
                if (++fbr.beat == fbr.len) fbr.busy = false;
            }
        }
        t->fbr_wait_n = !fbr.busy;
        t->fb_wait_n = 1;
        t->ee_valid = 0;
        if (eep.busy) {
            if (eep.rd) { t->ee_dout = ee[eep.a]; t->ee_valid = 1; }
            eep.busy = false;
        }
        t->ee_wait_n = !eep.busy;

#else
        {
            uint8_t rq = t->dbg_rom_req;
            uint8_t rise = rq & ~rom_req_prev, fall = ~rq & rom_req_prev;
            for (int p = 0; p < 7; p++) {
                if ((rise >> p) & 1) req_at[p] = cyc;
                if ((fall >> p) & 1) {
                    req_max_f[p] = std::max(req_max_f[p], cyc - req_at[p]);
                    if (p >= 2 && p <= 4) lat_hist[std::min<uint64_t>(127, cyc - req_at[p])]++;
                }
            }
            sprb_f += ((rise >> 5) & 1) + ((rise >> 6) & 1);
            rom_req_prev = rq;
            // the drawing time: from a swap to the last row written after it
            if (t->fb_rows_written != rows_seen) { rows_seen = t->fb_rows_written; draw_end = cyc; }
        }
#endif
        // ---- the 68000's bus, at each clk_cpu edge
        if (cpu_rose) {
            bool as = t->dbg_as;
            if (as && !as_prev) { as_start = cyc; waiting = true; bus_f++; if (t->dbg_fc == 7) irq_f++; }
            if (replay >= 0 && loaded_frame < 0 && as && t->dbg_rw && t->dbg_addr == 0x000500) {
                loaded_frame = frame;
                t->pause = 1;
                fprintf(stderr, "loaded in frame %d\n", frame);
            }
            if (as && t->dbg_dtack) {
                if (waiting) {
                    uint64_t w = cyc - as_start;
                    if (w > max_wait) { max_wait = w; max_wait_addr = t->dbg_addr; }
                    waiting = false;
                }
                rec_a = t->dbg_addr; rec_rd = t->dbg_rw;
                rec_m = (t->dbg_uds ? 0xff00 : 0) | (t->dbg_lds ? 0x00ff : 0);
                rec_d = (rec_rd ? t->dbg_din : t->dbg_dout) & rec_m;
                rec_iack = t->dbg_fc == 7;
                have_rec = true;
            }
            if (!as && as_prev) {
                as_hist[std::min<uint64_t>((cyc - as_start) / 3, 63)]++;
                as_clk_f += (cyc - as_start) / 3;
            }
            if (!as && as_prev && have_rec) {
                if (trace && !rec_iack && !(trace_data_only && rec_a >= 0x400 && rec_a < 0x100000)) {
                    fprintf(trace, "%06x %c %04x %04x\n", rec_a, rec_rd ? 'R' : 'W', rec_d, rec_m);
                    if (++traced >= trace_count && trace_count > 0) { fclose(trace); trace = nullptr; }
                }
                have_rec = false;
            }
            as_prev = as;
            bool sw = t->dbg_sprite_swap;
            if (sw && !swap_prev) swap_f++;
#ifdef POCKET_MEM
            if (sw && !swap_prev) {
                if (swap_at && draw_end > swap_at) draw_max_f = std::max(draw_max_f, draw_end - swap_at);
                swap_at = cyc;
            }
#endif
            swap_prev = sw;

            // the sound: a sample out and the next begun at each snd_sample
            clk_cpu_n++;
            if (ymz_read_pending) {      // the status a read latched, the clock after
                if (ymz_log)
                    fprintf(ymz_log, "%.12f S %02x%s\n", (ymz_read_at + 0.5) / snd_rate, t->dbg_ymz_dout,
                            ymz_read_mid ? " +" : "");
                ymz_read_pending = false;
            }
            if (t->snd_sample) {
                if (snd_started > 0) wav.push_back((int16_t)t->snd);
                snd_started++;
                snd_begin = cyc;
            }
            if (t->snd_overrun) { snd_late_f++; snd_late++; }
            bool sb = t->dbg_ymz_busy;
            if (snd_busy_prev && !sb) snd_max_f = std::max<uint64_t>(snd_max_f, (cyc - snd_begin) / 3);
            snd_busy_prev = sb;
            if (ymz_log || ymz_trace) {
                // an access on the clock a sample begins comes after it
                bool on_begin = t->dbg_ymz_begin;
                bool mid = sb || on_begin;
                long lands = snd_started + on_begin;
                uint64_t since = (cyc - snd_begin) / 3;
                if (ymz_trace && t->dbg_ymz_apply && !ymz_queued.empty()) {
                    fprintf(ymz_trace, "%s applied %llu\n", ymz_queued.front().c_str(),
                            (unsigned long long)clk_cpu_n);
                    ymz_queued.pop_front();
                }
                if (t->dbg_ymz_wr && !ymz_wr_prev) {
                    if (!t->dbg_ymz_a0) ymz_reg = t->dbg_ymz_din;
                    else {
                        if (ymz_log)
                            fprintf(ymz_log, "%.12f W %02x %02x%s\n", (lands + 0.5) / snd_rate, ymz_reg,
                                    t->dbg_ymz_din, mid ? " +" : "");
                        if (ymz_trace) {
                            char b[96];
                            snprintf(b, sizeof b, "%llu %ld %llu W %02x %02x%s%s", (unsigned long long)clk_cpu_n,
                                     lands, (unsigned long long)since, ymz_reg, t->dbg_ymz_din,
                                     mid ? " +" : "", on_begin ? " b" : "");
                            ymz_queued.push_back(b);
                        }
                    }
                }
                if (t->dbg_ymz_rd && !ymz_rd_prev && t->dbg_ymz_a0) {
                    ymz_read_pending = true; ymz_read_at = lands; ymz_read_mid = mid;
                    if (ymz_trace)
                        fprintf(ymz_trace, "%llu %ld %llu S%s%s\n", (unsigned long long)clk_cpu_n, lands,
                                (unsigned long long)since, mid ? " +" : "", on_begin ? " b" : "");
                }
            }
            ymz_wr_prev = t->dbg_ymz_wr;
            ymz_rd_prev = t->dbg_ymz_rd;
        }

        // ---- video capture, at each clk_vid edge
        if (vid_rose && t->ce_pix) {
            int hb = t->hblank, vb = t->vblank;
            if (!hb && !vb) {
                if (x < 320 && y < 240) {
                    uint8_t* px = &img[(y * 320 + x) * 3];
                    px[0] = t->r; px[1] = t->g; px[2] = t->b;
                }
                x++;
            }
            if (hb && !prev_hb && !vb) {
                y++; x = 0;
            }
            if (vb && !prev_vb) {
                if (trace) fprintf(trace, "# frame %d\n", frame);
                if (replay >= 0 && loaded_frame >= 0 && frame == loaded_frame + 4) {
                    char fn[512];
                    snprintf(fn, sizeof fn, "%s/frame_%05d.ppm", outdir.c_str(), replay);
                    FILE* f = fopen(fn, "wb");
                    fprintf(f, "P6\n320 240\n255\n");
                    fwrite(img.data(), 1, img.size(), f);
                    fclose(f);
                    std::vector<uint16_t> spr(320 * 240);
#ifdef POCKET_MEM
                    // the page on screen this frame: its chip, word y * 512 + x
                    {
                        auto& c0 = t->rootp->cave68000_psim__DOT__chip__BRA__0__KET____DOT__dev__DOT__mem;
                        auto& c1 = t->rootp->cave68000_psim__DOT__chip__BRA__1__KET____DOT__dev__DOT__mem;
                        bool one = t->dbg_fb_read_page & 1;
                        for (int yy = 0; yy < 240; yy++)
                            for (int xx = 0; xx < 320; xx++)
                                spr[yy * 320 + xx] = one ? c1[yy * 512 + xx] : c0[yy * 512 + xx];
                    }
#else
                    // the page on screen this frame: rows of 512 pixels, four to a word
                    uint32_t page = (uint32_t)t->dbg_fb_read_page << 16;
                    for (int yy = 0; yy < 240; yy++)
                        for (int xx = 0; xx < 320; xx++)
                            spr[yy * 320 + xx] = (uint16_t)(fbmem[(page + yy * 128 + xx / 4) & ((1u << 18) - 1)] >> (16 * (xx % 4)));
#endif
                    snprintf(fn, sizeof fn, "%s/sprites_%05d.bin", outdir.c_str(), replay);
                    f = fopen(fn, "wb");
                    fwrite(spr.data(), 2, spr.size(), f);
                    fclose(f);
                    replay_done = true;
                }
                if (all_frames || dumps.count(frame)) {
                    char fn[512];
                    snprintf(fn, sizeof fn, "%s/frame_%05d.ppm", outdir.c_str(), frame);
                    FILE* f = fopen(fn, "wb");
                    fprintf(f, "P6\n320 240\n255\n");
                    fwrite(img.data(), 1, img.size(), f);
                    fclose(f);
                }
#ifdef POCKET_MEM
                fbr_f = (uint16_t)(t->fb_rows_read - rows_r_prev);
                fbw_f = (uint16_t)(t->fb_rows_written - rows_w_prev);
                rows_r_prev = t->fb_rows_read; rows_w_prev = t->fb_rows_written;
#endif
                fprintf(stats, "%d,%llu,%llu,%llu,%06x,%llu,%llu,%llu,%llu,%llu,%llu,%llu", frame,
                        (unsigned long long)cyc, (unsigned long long)bus_f,
                        (unsigned long long)max_wait, max_wait_addr,
                        (unsigned long long)irq_f, (unsigned long long)swap_f,
                        (unsigned long long)sprb_f, (unsigned long long)fbr_f, (unsigned long long)fbw_f,
                        (unsigned long long)snd_max_f, (unsigned long long)snd_late_f);
                fprintf(stats, ",%llu", (unsigned long long)as_clk_f);
                as_clk_f = 0;
#ifdef POCKET_MEM
                // the longest draw (clk from a swap to the last row written
                // after it) and the longest a line read waited for its first row
                fprintf(stats, ",%llu,%u", (unsigned long long)draw_max_f, (unsigned)t->fb_rd_wait_max);
                for (int p = 0; p < 7; p++) {
                    fprintf(stats, ",%llu", (unsigned long long)req_max_f[p]);
                    req_max[p] = std::max(req_max[p], req_max_f[p]); req_max_f[p] = 0;
                }
                draw_max = std::max(draw_max, draw_max_f); draw_max_f = 0;
#endif
                fprintf(stats, "\n");
                fflush(stats);
                if (ymz_log) fprintf(ymz_log, "# frame %d %.12f\n", frame, (snd_started + 0.5) / snd_rate);
                bus_f = irq_f = swap_f = sprb_f = fbr_f = fbw_f = 0;
                snd_max_f = snd_late_f = 0;
                max_wait = 0; max_wait_addr = 0;
                if (frame % 10 == 0) fprintf(stderr, "frame %d  cycles %llu\n", frame, (unsigned long long)cyc);
                frame++;
                // the inputs for the frame now begun, set where MAME's
                // notifier for the one just ended sets them
                if (!presses.empty()) {
                    uint8_t in[6] = {0, 0, 0, 0, 0, 0};
                    for (auto& pr : presses)
                        if (frame - 1 >= pr.from && frame - 1 <= pr.to) in[pr.port] |= 1u << pr.bit;
                    t->p1 = in[0]; t->p2 = in[1]; t->coin = in[2]; t->start = in[3]; t->service = in[4];
                    if (replay < 0) t->pause = in[5];
                }
                y = 0; x = 0;
            }
            if (!vb && prev_vb) { y = 0; x = 0; }
            prev_hb = hb; prev_vb = vb;
        }
    }

    if (trace) fclose(trace);
    fclose(stats);
    if (ymz_log) fclose(ymz_log);
    if (ymz_trace) fclose(ymz_trace);
    if (wav_path) {
        FILE* f = fopen(wav_path, "wb");
        if (!f) { perror(wav_path); return 1; }
        auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
        auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
        uint32_t bytes = wav.size() * 2, rate = (uint32_t)snd_rate;
        fwrite("RIFF", 1, 4, f); u32(36 + bytes); fwrite("WAVEfmt ", 1, 8, f);
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
        fwrite("data", 1, 4, f); u32(bytes);
        fwrite(wav.data(), 2, wav.size(), f);
        fclose(f);
    }
    if (snd_started > 0)
        fprintf(stderr, "sound: %ld samples, %llu late\n", snd_started, (unsigned long long)snd_late);
#ifdef POCKET_MEM
    fprintf(stderr, "memory models: %u SDRAM violations, %u PSRAM violations; longest draw %llu clk, "
            "longest line read wait %u clk\n",
            (unsigned)t->sdram_violations, (unsigned)t->psram_violations,
            (unsigned long long)draw_max, (unsigned)t->fb_rd_wait_max);
    fprintf(stderr, "longest request to acknowledge, clk: program %llu, samples %llu, layers %llu %llu %llu, sprites %llu %llu\n",
            (unsigned long long)req_max[0], (unsigned long long)req_max[1], (unsigned long long)req_max[2],
            (unsigned long long)req_max[3], (unsigned long long)req_max[4], (unsigned long long)req_max[5],
            (unsigned long long)req_max[6]);
    if (getenv("LAT_HIST"))
        for (int i = 0; i < 128; i++) if (lat_hist[i]) fprintf(stderr, "  layer line read %3d clk: %llu\n", i, (unsigned long long)lat_hist[i]);
#endif
    if (getenv("AS_HIST"))
        for (int i = 0; i < 64; i++) if (as_hist[i]) fprintf(stderr, "  AS held %2d clk_cpu: %llu\n", i, (unsigned long long)as_hist[i]);
    if (replay >= 0 && !replay_done) {
        fprintf(stderr, loaded_frame < 0 ? "the loader never finished\n" : "ran out of frames\n");
        return 1;
    }
    t->final();
    delete t;
    return 0;
}
