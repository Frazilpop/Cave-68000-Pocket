// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 (Pocket) — Air Gallet's and Sailor Moon's sound board on its own:
// rtl/cave/SoundZ80.sv driven by the 68000's side of a sound-board log
// (tools/mame_cave_z80.lua's), its Z80's accesses held to MAME's.
//
//   tb_z80 <log> <set.rom> [--seconds S] [--lat N] [--mem] [--out PREFIX]
//          [--log FILE] [--quiet]
//
// The 68000's sound commands (C W b8006e) are written to the latch on the
// clock of their time, llround(t * 32 MHz); its reads of the reply FIFO
// (C R b8006e) take the FIFO's head on theirs, and what they take is compared
// with what MAME's 68000 read. The board's reset is MAME's time 0. The sound
// ROM port serves the image's Z80, OKI 0 and OKI 1 regions (from 0x400080,
// build_rom.py's layout for games 9 and 10), --lat clocks after a read is
// taken (default 12).
//
// Compared, access for access, with the log's: every I/O access of the Z80
// (Z lines: port, direction, data, and the clock it was made on, less the
// clocks the Z80 was behind its own time), and with --mem every memory access
// at 4000-ffff (M lines; the log must be a Z80_MEM=1 one). The first that
// differs is printed with the ones before it; the times' differences are
// counted.
//
// --log FILE writes the board's own accesses in the log's format, at the
// Z80's own time, for sim/ym2151/tb_ym2151 and tools/pocket/oki_model.py
// --z80. --out PREFIX writes PREFIX_ym.raw (the YM2151's samples, int16 left
// and right at 62,500 Hz), PREFIX.0 and PREFIX.1 (each OKI's, int32 as
// oki_model.py's --out) and PREFIX_mix.raw (the board's output, int16 at
// 88,200 Hz).
#include "VSoundZ80.h"
#include "verilated.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

static const double CLOCK = 32000000.0;
static const size_t Z80_REGION = 0x400080;   // build_rom.py OFFSETS[9]["z80"]

struct Cmd { long long cyc; bool rd; int data; };
struct Acc { long long cyc; char kind; bool wr; int addr; int data; double t; };

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 3) {
    fprintf(stderr, "usage: tb_z80 <log> <set.rom> [--seconds S] [--lat N] [--mem] [--out PREFIX] [--log FILE] [--quiet]\n");
    return 2;
  }
  double seconds = 1e9;
  int lat = 12;
  long long base = 0;       // the clocks every access is expected off MAME's
  int showOff = 0;          // print this many accesses off base
  bool mem = false, quiet = false;
  const char *out = nullptr, *logOut = nullptr;
  for (int i = 3; i < argc; i++) {
    if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
    else if (!strcmp(argv[i], "--lat") && i + 1 < argc) lat = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--mem")) mem = true;
    else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
    else if (!strcmp(argv[i], "--log") && i + 1 < argc) logOut = argv[++i];
    else if (!strcmp(argv[i], "--quiet")) quiet = true;
    else if (!strcmp(argv[i], "--base") && i + 1 < argc) base = atoll(argv[++i]);
    else if (!strcmp(argv[i], "--show-off") && i + 1 < argc) showOff = atoi(argv[++i]);
  }

  // ---------------------------------------------------------------- the log
  std::vector<Cmd> cmds;
  std::vector<Acc> want;
  double endT = 0;
  {
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 1; }
    char line[256];
    while (fgets(line, sizeof line, f)) {
      if (line[0] == '#') {
        double t;
        if (sscanf(line, "# frame %*d %lf", &t) == 1 && t <= seconds) endT = t;
        continue;
      }
      double t; char k, rw; unsigned a, d;
      if (sscanf(line, "%lf %c %c %x %x", &t, &k, &rw, &a, &d) != 5) continue;
      if (t > seconds) continue;
      long long cyc = llround(t * CLOCK);
      if (k == 'C') {
        if (a == 0xb8006e) cmds.push_back({cyc, rw == 'R', (int)d});
      } else if (k == 'Z' || (k == 'M' && mem)) {
        want.push_back({cyc, k, rw == 'W', (int)a, (int)d, t});
      }
    }
    fclose(f);
  }
  std::stable_sort(cmds.begin(), cmds.end(), [](const Cmd &x, const Cmd &y) { return x.cyc < y.cyc; });
  std::stable_sort(want.begin(), want.end(), [](const Acc &x, const Acc &y) { return x.cyc < y.cyc; });
  if (seconds > 1e8) seconds = endT;
  long long endCyc = llround(seconds * CLOCK);

  std::vector<uint8_t> rom;
  {
    FILE *f = fopen(argv[2], "rb");
    if (!f) { perror(argv[2]); return 1; }
    fseek(f, 0, SEEK_END);
    rom.resize(ftell(f));
    fseek(f, 0, SEEK_SET);
    if (fread(rom.data(), 1, rom.size(), f) != rom.size()) { perror(argv[2]); return 1; }
    fclose(f);
  }
  if (rom.size() < Z80_REGION + 0x480000) { fprintf(stderr, "%s: too small for game 9/10\n", argv[2]); return 1; }

  fprintf(stderr, "%zu commands and reply reads, %zu accesses to match, %.3f s\n", cmds.size(), want.size(), seconds);

  // -------------------------------------------------------------- the board
  VSoundZ80 *top = new VSoundZ80;
  auto tick = [&]() {
    top->clock = 0; top->io_load_clock = 0; top->eval();
    top->clock = 1; top->io_load_clock = 1; top->eval();
  };
  top->reset = 1;
  top->io_pause = 0;
  top->io_cmd_wr = 0;
  top->io_reply_rd = 0;
  top->io_rom_wait_n = 1;
  top->io_rom_valid = 0;
  top->io_load_wr = 1;
  for (int w = 0; w < 8192; w++) {
    top->io_load_addr = w;
    top->io_load_data = rom[Z80_REGION + 2 * w] | (rom[Z80_REGION + 2 * w + 1] << 8);
    tick();
  }
  top->io_load_wr = 0;
  for (int i = 0; i < 4; i++) tick();
  top->reset = 0;

  FILE *flog = logOut ? fopen(logOut, "w") : nullptr;
  if (flog) fprintf(flog, "# board\n");
  std::vector<int16_t> ymOut, mixOut;
  std::vector<int32_t> oki0Out, oki1Out;

  size_t ci = 0, wi = 0;
  long long matched = 0, firstBad = -1;
  long long timeDiff = 0, maxLate = 0, holdClocks = 0, accesses = 0, lateIo = 0;
  std::map<long long, long long> diffHist;
  long replyBad = 0, replyReads = 0, replyTaken = 0;
  // the port
  bool busy = false, portErr = false; long long readyAt = 0; uint32_t portAddr = 0;
  std::vector<Acc> recent;

  for (long long n = 0; n < endCyc; n++) {
    top->io_cmd_wr = 0;
    top->io_reply_rd = 0;
    while (ci < cmds.size() && cmds[ci].cyc <= n) {
      const Cmd &c = cmds[ci++];
      if (!c.rd) {
        top->io_cmd_wr = 1;
        top->io_cmd_data = c.data;
      } else {
        replyReads++;
        top->clock = 0; top->eval();
        int got = top->io_reply_empty ? 0x00ff : (top->io_reply & 0xffff);
        if (!top->io_reply_empty) { top->io_reply_rd = 1; replyTaken++; }
        if (got != c.data) {
          if (replyBad == 0 && !quiet)
            printf("reply read at %.9f s: MAME %04x, board %04x\n", c.cyc / CLOCK, c.data, got);
          replyBad++;
        }
      }
    }
    // the port: one read at a time, lat clocks
    top->io_rom_valid = 0;
    if (busy && n >= readyAt) {
      top->io_rom_valid = 1;
      top->io_rom_dout = rom[Z80_REGION + portAddr];
      busy = false;
    }
    top->io_rom_wait_n = !busy;
    top->clock = 0; top->eval();
    // the board's freezer answers only the address it is shown
    if (busy && top->io_rom_addr != portAddr && !portErr) {
      portErr = true;
      printf("port: address %06x shown while %06x is outstanding, at %.9f s\n", (unsigned)top->io_rom_addr,
             portAddr, n / CLOCK);
    }
    if (top->io_rom_rd && !busy) {
      busy = true;
      readyAt = n + lat;
      portAddr = top->io_rom_addr;
      if (Z80_REGION + portAddr >= rom.size()) portAddr = 0;
    }
    if (top->dbg_hold) holdClocks++;
    top->clock = 1; top->eval();

    if (top->dbg_acc) {
      accesses++;
      long long late = top->dbg_acc_late;
      long long cyc = (long long)top->dbg_acc_time;   // the sound board's own clock
      if (late > maxLate) maxLate = late;
      if (late > 0 && top->dbg_acc_io) lateIo++;
      int addr = top->dbg_acc_addr, data = top->dbg_acc_data;
      bool io = top->dbg_acc_io, wr = top->dbg_acc_wr;
      bool m1 = top->dbg_acc_m1;
      bool logged = io || (!m1 && addr >= 0x4000) || (m1 && addr >= 0x4000);
      if (io) addr &= 0xff;
      if (logged && flog)
        fprintf(flog, "%.12f %c %c %0*x %02x\n", cyc / CLOCK, io ? 'Z' : 'M', wr ? 'W' : 'R', io ? 2 : 4, addr, data);
      if (logged && (io || mem)) {
        Acc a{cyc, io ? 'Z' : 'M', wr, addr, data, cyc / CLOCK};
        if (firstBad < 0) {
          if (wi < want.size()) {
            const Acc &w = want[wi];
            if (w.kind == a.kind && w.wr == a.wr && w.addr == a.addr && w.data == a.data) {
              matched++;
              long long d = cyc - w.cyc - base;
              diffHist[d]++;
              if (d != 0) {
                timeDiff++;
                if (showOff > 0) {
                  showOff--;
                  printf("  off %+lld: MAME %.9f %c %c %04x %02x (previous at %.9f)\n", d, w.t, w.kind,
                         w.wr ? 'W' : 'R', w.addr, w.data, wi ? want[wi - 1].t : 0.0);
                }
              }
              wi++;
            } else {
              firstBad = (long long)wi;
              if (!quiet) {
                printf("access %lld differs:\n", (long long)wi);
                size_t from = wi >= 6 ? wi - 6 : 0;
                for (size_t j = from; j < wi + 6 && j < want.size(); j++)
                  printf("  MAME  %.9f %c %c %04x %02x%s\n", want[j].t, want[j].kind, want[j].wr ? 'W' : 'R',
                         want[j].addr, want[j].data, j == wi ? "   <-" : "");
                for (auto &r : recent)
                  printf("  board %.9f %c %c %04x %02x\n", r.t, r.kind, r.wr ? 'W' : 'R', r.addr, r.data);
                printf("  board %.9f %c %c %04x %02x   <-\n", a.t, a.kind, a.wr ? 'W' : 'R', a.addr, a.data);
              }
            }
          }
          recent.push_back(a);
          if (recent.size() > 6) recent.erase(recent.begin());
        }
      }
    }
    if (top->dbg_ym_sample) { ymOut.push_back((int16_t)top->dbg_ym_left); ymOut.push_back((int16_t)top->dbg_ym_right); }
    if (top->dbg_oki_sv0) oki0Out.push_back((int32_t)(top->dbg_oki_s0 << 12) >> 12);
    if (top->dbg_oki_sv1) oki1Out.push_back((int32_t)(top->dbg_oki_s1 << 12) >> 12);
    if (top->io_audio_valid) mixOut.push_back((int16_t)top->io_audio);
    if (top->io_overrun && !quiet) printf("overrun at %.9f s\n", n / CLOCK);
  }

  size_t toMatch = want.size();
  printf("%s: %lld of %zu accesses equal%s", argv[1], matched, toMatch,
         firstBad < 0 ? (wi == toMatch ? " (all)" : " (the board stopped short)") : "");
  if (firstBad >= 0) printf(", the first to differ %lld", firstBad);
  printf("\n  on MAME's clock %lld, off it %lld:", matched - timeDiff, timeDiff);
  int shown = 0;
  for (auto &h : diffHist)
    if (h.first != 0 && shown++ < 12) printf(" %+lld x%lld", h.first, h.second);
  printf("\n  the Z80 stood %lld clocks for the banked ROM, at most %lld behind; %lld accesses in all,"
         " %lld to a port while behind\n", holdClocks, maxLate, accesses, lateIo);
  printf("  reply reads: %ld, %ld taken, %ld not what MAME's 68000 read\n", replyReads, replyTaken, replyBad);
  printf("  samples: YM2151 %zu, OKI %zu / %zu, out %zu\n", ymOut.size() / 2, oki0Out.size(), oki1Out.size(), mixOut.size());
  if (flog) fclose(flog);
  if (out) {
    std::string p(out);
    FILE *f;
    if ((f = fopen((p + "_ym.raw").c_str(), "wb"))) { fwrite(ymOut.data(), 2, ymOut.size(), f); fclose(f); }
    if ((f = fopen((p + ".0").c_str(), "wb"))) { fwrite(oki0Out.data(), 4, oki0Out.size(), f); fclose(f); }
    if ((f = fopen((p + ".1").c_str(), "wb"))) { fwrite(oki1Out.data(), 4, oki1Out.size(), f); fclose(f); }
    if ((f = fopen((p + "_mix.raw").c_str(), "wb"))) { fwrite(mixOut.data(), 2, mixOut.size(), f); fclose(f); }
  }
  delete top;
  return (firstBad >= 0 || wi != toMatch) ? 1 : 0;
}
