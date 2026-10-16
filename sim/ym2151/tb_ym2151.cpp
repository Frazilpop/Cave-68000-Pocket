// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket: the board's YM2151 (rtl/cave/YM2151.sv)
// against MAME's own (ymfm, BSD-3-Clause, compiled in from
// third_party/mame/3rdparty/ymfm) on the same register writes, sample for
// sample, and against the status MAME's Z80 read.
//
//   $OBJ/tb_ym2151 <log> [--seconds S] [--out prefix] [--ops] [--quiet]
//
// The log is tools/mame_cave_z80.lua's: "<t> Z W 50 <reg>" and
// "<t> Z W 51 <data>" are the Z80's writes to the chip's address and data
// ports, "<t> Z R 51 <status>" its status reads, at machine time t. The
// chip is run as the board runs it: a 32 MHz clock, phiM (cen) every 8th,
// the timers and busy flag counted at the Z80's 8 MHz (cen_t every 4th,
// TSCALE 2), each access made on the clock of its time. MAME
// (ymfm_device_base::write) brings the chip's stream up to t – every sample
// k with k < ceil(t * 62,500) made – before it takes a write; the reference
// does the same.
//
// Reported: the samples that differ (none expected, at no lag), the first
// with both sides; with --ops, the first sample after which an operator's
// envelope state, attenuation or phase differ; the status reads that differ
// from the log's (busy, the timer flags).
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <string>
#include "VYM2151.h"
#include "VYM2151___024root.h"
#include "verilated.h"
#include "ymfm_opm.h"

struct Access { long long cyc; bool rd; int a0; int data; };

struct Intf : ymfm::ymfm_interface {};

struct Ym2151 : ymfm::ym2151 {
  using ymfm::ym2151::ym2151;
  ymfm::ym2151::fm_engine &fm() { return m_fm; }
};

static const double CLOCK = 32000000.0;
static const long long SAMPLE_CYC = 512;   // 32 MHz / 62,500

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) { fprintf(stderr, "usage: tb_ym2151 <log> [--seconds S] [--out prefix] [--ops]\n"); return 2; }
  double seconds = 1e9;
  const char *out = nullptr;
  bool ops = false, quiet = false;
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
    else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
    else if (!strcmp(argv[i], "--ops")) ops = true;
    else if (!strcmp(argv[i], "--quiet")) quiet = true;
  }
  std::vector<Access> acc;
  FILE *f = fopen(argv[1], "r");
  if (!f) { perror(argv[1]); return 1; }
  char line[256];
  while (fgets(line, sizeof line, f)) {
    double t; char k, rw; unsigned port, data;
    if (sscanf(line, "%lf %c %c %x %x", &t, &k, &rw, &port, &data) != 5) continue;
    if (k != 'Z' || (port != 0x50 && port != 0x51)) continue;
    if (t > seconds) break;
    acc.push_back({llround(t * CLOCK), rw == 'R', (int)(port & 1), (int)data});
  }
  fclose(f);
  long long lastCyc = acc.empty() ? 0 : acc.back().cyc;
  long nsamp = seconds < 1e8 ? (long)(seconds * 62500) : (long)(lastCyc / SAMPLE_CYC) + 2 * 62500;
  long nw = 0, nr = 0;
  for (auto &a : acc) (a.rd ? nr : nw)++;
  fprintf(stderr, "%ld writes, %ld status reads, %ld samples (%.2f s)\n", nw, nr, nsamp, nsamp / 62500.0);

  // reference: MAME's ymfm, a write at cycle w landing before sample ceil(w / 512)
  Intf intf;
  Ym2151 chip(intf);
  chip.reset();
  std::vector<int16_t> rl, rr;
  std::vector<uint32_t> rop;   // per sample, 32 operators: state << 30 | att << 20 | phase >> 10 << 10
  rl.reserve(nsamp); rr.reserve(nsamp);
  if (ops) rop.reserve((size_t)nsamp * 32);
  size_t wi = 0;
  for (long k = 0; k < nsamp; k++) {
    while (wi < acc.size() && (acc[wi].rd || (acc[wi].cyc + SAMPLE_CYC - 1) / SAMPLE_CYC <= k)) {
      if (!acc[wi].rd) { if (acc[wi].a0) chip.write_data(acc[wi].data); else chip.write_address(acc[wi].data); }
      wi++;
    }
    ymfm::ym2151::output_data o;
    chip.generate(&o, 1);
    rl.push_back((int16_t)o.data[0]); rr.push_back((int16_t)o.data[1]);
    if (ops)
      for (int s = 0; s < 32; s++) {
        auto *op = chip.fm().debug_operator(s);
        rop.push_back(((uint32_t)(op->debug_eg_state() - 1) << 30) | ((uint32_t)op->debug_eg_attenuation() << 20) |
                      ((op->phase() & 0x3ff) << 10));
      }
  }

  // the board's chip
  VYM2151 *ym = new VYM2151;
  ym->reset = 1; ym->cen = 0; ym->cen_t = 0; ym->io_wr = 0; ym->io_a0 = 0; ym->io_din = 0;
  for (int i = 0; i < 4; i++) { ym->clock = 0; ym->eval(); ym->clock = 1; ym->eval(); }
  ym->reset = 0;
  for (int i = 0; i < 40; i++) { ym->clock = 0; ym->eval(); ym->clock = 1; ym->eval(); }   // its init
  std::vector<int16_t> jl, jr;
  jl.reserve(nsamp); jr.reserve(nsamp);
  long statusDiff = 0, statusFirst = -1, busyDiff = 0, flagDiff = 0;
  long opsFirst = -1; int opsSlot = -1; uint32_t opsRef = 0, opsRtl = 0;
  size_t ai = 0;
  for (long long cyc = 0; (long)jl.size() < nsamp; cyc++) {
    ym->cen = (cyc & 7) == 0;
    ym->cen_t = (cyc & 3) == 0;
    ym->io_wr = 0;
    while (ai < acc.size() && acc[ai].cyc < cyc) ai++;   // two on one clock: the first taken
    if (ai < acc.size() && acc[ai].cyc == cyc) {
      const Access &a = acc[ai++];
      ym->io_a0 = a.a0;
      if (a.rd) {
        ym->clock = 0; ym->eval();
        int s = ym->io_dout;
        if (s != a.data) {
          statusDiff++;
          if ((s ^ a.data) & 0x80) busyDiff++;
          if ((s ^ a.data) & 0x03) flagDiff++;
          if (statusFirst < 0) {
            statusFirst = (long)(ai - 1);
            if (!quiet) printf("status at %.9f s: log %02x, chip %02x\n", a.cyc / CLOCK, a.data, s);
          }
        }
      } else {
        ym->io_wr = 1; ym->io_din = a.data;
      }
    }
    ym->clock = 0; ym->eval(); ym->clock = 1; ym->eval();
    if (ym->io_sample) {
      long k = (long)jl.size();
      jl.push_back((int16_t)ym->io_left); jr.push_back((int16_t)ym->io_right);
      if (ops && opsFirst < 0) {
        // (the operators' state is written back before the sample is out)
        for (int s = 0; s < 32 && opsFirst < 0; s++) {
          uint64_t v = ym->rootp->YM2151__DOT__ost[s];
          uint32_t r = ((uint32_t)((v >> 30) & 3) << 30) | ((uint32_t)((v >> 20) & 0x3ff) << 20) |
                       ((uint32_t)((v >> 10) & 0x3ff) << 10);
          if (r != rop[(size_t)k * 32 + s]) { opsFirst = k; opsSlot = s; opsRef = rop[(size_t)k * 32 + s]; opsRtl = r; }
        }
      }
    }
  }
  if (ym->io_overrun) printf("overrun flagged\n");

  long diff = 0, nonzero = 0, first = -1, maxd = 0;
  for (long k = 0; k < nsamp; k++) {
    if (rl[k] || rr[k]) nonzero++;
    if (rl[k] != jl[k] || rr[k] != jr[k]) {
      if (first < 0) first = k;
      diff++;
      maxd = std::max(maxd, (long)std::max(std::abs(rl[k] - jl[k]), std::abs(rr[k] - jr[k])));
    }
  }
  printf("%ld of %ld samples equal (%ld not silent in ymfm), %ld differ, first at %ld (%.4f s), largest difference %ld\n",
         nsamp - diff, nsamp, nonzero, diff, first, first / 62500.0, maxd);
  if (first >= 0 && !quiet)
    for (long k = first; k < first + 8 && k < nsamp; k++)
      printf("  %ld: ymfm %6d %6d  chip %6d %6d\n", k, rl[k], rr[k], jl[k], jr[k]);
  printf("status reads: %ld of %ld differ (busy %ld, timer flags %ld)\n", statusDiff, nr, busyDiff, flagDiff);
  if (ops) {
    if (opsFirst < 0) printf("operators: every one equal after every sample\n");
    else printf("operators: slot %d differs after sample %ld: ymfm state %u att %03x phase %03x, chip state %u att %03x phase %03x\n",
                opsSlot, opsFirst, opsRef >> 30, (opsRef >> 20) & 0x3ff, (opsRef >> 10) & 0x3ff,
                opsRtl >> 30, (opsRtl >> 20) & 0x3ff, (opsRtl >> 10) & 0x3ff);
  }
  if (out) {
    std::string a = std::string(out) + "_ymfm.raw", b = std::string(out) + "_chip.raw";
    FILE *fa = fopen(a.c_str(), "wb"), *fb = fopen(b.c_str(), "wb");
    for (long k = 0; k < nsamp; k++) { int16_t s[2] = {rl[k], rr[k]}; fwrite(s, 2, 2, fa); }
    for (long k = 0; k < nsamp; k++) { int16_t s[2] = {jl[k], jr[k]}; fwrite(s, 2, 2, fb); }
    fclose(fa); fclose(fb);
  }
  delete ym;
  return diff != 0 || statusDiff != 0;
}
