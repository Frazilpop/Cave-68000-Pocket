// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 (Pocket) — whole-board harness.
//
//   tb_ddonpach <set.rom> <game id> <frames> <outdir> [dump frames, comma list]
//          [--rom-lat N] [--spr-lat N] [--fb-lat N] [--all-frames]
//          [--trace file] [--trace-count N] [--trace-data-only]
//          [--prog file --replay N]
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
// at the first vblank, as MAME's frame notifier does.
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

#include "Vcave68000_sim.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
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
    Vcave68000_sim* t = new Vcave68000_sim;

    t->game = game;
    t->rst = 1; t->rst_cpu = 1; t->rst_vid = 1; t->rom_loaded = 0;
    t->p1 = 0; t->p2 = 0; t->coin = 0; t->start = 0; t->service = 0; t->pause = 0;
    t->dsw = 0xfffb;
    t->clk = 0; t->clk_cpu = 0; t->clk_vid = 0;
    t->eval();
    {
        uint32_t off = t->eeprom_offset;
        for (int i = 0; i < 64; i++) ee[i] = (uint16_t)(rom[off + 2 * i] << 8 | rom[off + 2 * i + 1]);
    }

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

    t->prog_wait_n = 1; t->snd_wait_n = 1; t->tile_wait_n = 7;
    t->spr_wait_n = 1; t->fb_wait_n = 1; t->ee_wait_n = 1;

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
    fprintf(stats, "frame,cycles,bus_cycles,max_wait,max_wait_addr,irqs,swaps,spr_bursts,fb_rd_bursts,fb_wr_beats\n");

    // ------------------------------------------------------------- monitors
    FILE* trace = trace_path ? fopen(trace_path, "w") : nullptr;
    long traced = 0;
    bool as_prev = false, have_rec = false;
    uint32_t rec_a = 0, rec_d = 0, rec_m = 0; bool rec_rd = false, rec_iack = false;
    uint64_t as_start = 0, max_wait = 0; uint32_t max_wait_addr = 0; bool waiting = false;
    uint64_t bus_f = 0, irq_f = 0, swap_f = 0, sprb_f = 0, fbr_f = 0, fbw_f = 0;
    bool swap_prev = false;
    int loaded_frame = -1;       // --replay: the frame the loader finished in
    bool replay_done = false;

    while (frame <= frames && !replay_done) {
        // ---- the falling half: the board settles on this period's inputs
        half(0);

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
        if (t->fb_rd && t->fb_wait_n) {
            fbr.busy = true; fbr.cnt = fb_lat; fbr.addr = t->fb_addr; fbr.len = t->fb_len; fbr.beat = 0;
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

        // ---- the rising half
        half(1);
        cyc++;

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
        t->fb_valid = 0;
        if (fbr.busy) {
            if (fbr.cnt > 0) fbr.cnt--;
            else {
                t->fb_dout = fbmem[((fbr.addr >> 3) + fbr.beat) & ((1u << 18) - 1)]; t->fb_valid = 1;
                if (++fbr.beat == fbr.len) fbr.busy = false;
            }
        }
        t->fb_wait_n = !fbr.busy;
        t->ee_valid = 0;
        if (eep.busy) {
            if (eep.rd) { t->ee_dout = ee[eep.a]; t->ee_valid = 1; }
            eep.busy = false;
        }
        t->ee_wait_n = !eep.busy;

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
            swap_prev = sw;
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
                    // the page on screen this frame: rows of 512 pixels, four to a word
                    uint32_t page = (uint32_t)t->dbg_fb_read_page << 16;
                    std::vector<uint16_t> spr(320 * 240);
                    for (int yy = 0; yy < 240; yy++)
                        for (int xx = 0; xx < 320; xx++)
                            spr[yy * 320 + xx] = (uint16_t)(fbmem[(page + yy * 128 + xx / 4) & ((1u << 18) - 1)] >> (16 * (xx % 4)));
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
                fprintf(stats, "%d,%llu,%llu,%llu,%06x,%llu,%llu,%llu,%llu,%llu\n", frame,
                        (unsigned long long)cyc, (unsigned long long)bus_f,
                        (unsigned long long)max_wait, max_wait_addr,
                        (unsigned long long)irq_f, (unsigned long long)swap_f,
                        (unsigned long long)sprb_f, (unsigned long long)fbr_f, (unsigned long long)fbw_f);
                fflush(stats);
                bus_f = irq_f = swap_f = sprb_f = fbr_f = fbw_f = 0;
                max_wait = 0; max_wait_addr = 0;
                if (frame % 10 == 0) fprintf(stderr, "frame %d  cycles %llu\n", frame, (unsigned long long)cyc);
                frame++;
                y = 0; x = 0;
            }
            if (!vb && prev_vb) { y = 0; x = 0; }
            prev_hb = hb; prev_vb = vb;
        }
    }

    if (trace) fclose(trace);
    fclose(stats);
    if (replay >= 0 && !replay_done) {
        fprintf(stderr, loaded_frame < 0 ? "the loader never finished\n" : "ran out of frames\n");
        return 1;
    }
    t->final();
    delete t;
    return 0;
}
