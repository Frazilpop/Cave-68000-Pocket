// SPDX-License-Identifier: GPL-3.0-or-later
// Cave 68000 for Analogue Pocket: jt51 against MAME's own YM2151 (ymfm,
// BSD-3-Clause, compiled in from third_party/mame/3rdparty/ymfm) on the same
// register writes, sample for sample.
//
//   $OBJ/tb_jt51 <log> [--seconds S] [--out prefix] [--shift phiM clocks]
//
// The log is tools/mame_cave_z80.lua's: "<t> Z W 50 <reg>" and
// "<t> Z W 51 <data>" are the Z80's writes to the chip's address and data
// ports, at machine time t. MAME (ymfm_device_base::write) brings the
// chip's stream up to t – every sample k with k < ceil(t * rate) generated –
// before it takes the write; the reference does the same at 4 MHz / 64 =
// 62,500 Hz. jt51 is clocked at the chip's own rate: cen at 4 MHz (phiM),
// cen_p1 every second cen; each write is presented for one cen_p1 at the
// chip clock the reference applies it, and a sample is taken at each
// 'sample' strobe (left/right: the YM3012's 10.3 floating point, as ymfm's
// roundtrip_fp). The two streams are compared at every lag in -64..64 and
// the best is reported, then the samples that differ at it.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <string>
#include "Vjt51.h"
#include "verilated.h"
#include "Vjt51___024root.h"
#include "ymfm_opm.h"

struct Write { double t; int a0; int data; };

struct Intf : ymfm::ymfm_interface {};

// the engine, for the envelope dump (--eg): ym2151 keeps it protected
struct Ym2151 : ymfm::ym2151 {
  using ymfm::ym2151::ym2151;
  ymfm::ym2151::fm_engine &fm() { return m_fm; }
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) { fprintf(stderr, "usage: tb_jt51 <log> [--seconds S] [--out prefix]\n"); return 2; }
  double seconds = 1e9;
  long shift = 0;     // phiM clocks added to every write's time on jt51's side
  const char *egout = nullptr;   // per sample: ymfm's operator 0 attenuation, jt51's eg at each of the 32 slots
  const char *out = nullptr;
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atof(argv[++i]);
    else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
    else if (!strcmp(argv[i], "--shift") && i + 1 < argc) shift = atol(argv[++i]);
    else if (!strcmp(argv[i], "--eg") && i + 1 < argc) egout = argv[++i];
  }
  std::vector<Write> w;
  FILE *f = fopen(argv[1], "r");
  if (!f) { perror(argv[1]); return 1; }
  char line[256];
  while (fgets(line, sizeof line, f)) {
    double t; char k, rw; unsigned port, data;
    if (sscanf(line, "%lf %c %c %x %x", &t, &k, &rw, &port, &data) != 5) continue;
    if (k != 'Z' || rw != 'W' || (port != 0x50 && port != 0x51)) continue;
    if (t > seconds) break;
    w.push_back({t, (int)(port & 1), (int)data});
  }
  fclose(f);
  const double rate = 4000000.0 / 64;
  long nsamp = (long)std::floor((w.empty() ? 0 : w.back().t) * rate) + 2 * 62500;
  if (seconds < 1e8) nsamp = (long)(seconds * rate);
  fprintf(stderr, "%zu writes, %ld samples (%.2f s)\n", w.size(), nsamp, nsamp / rate);

  // reference: MAME's ymfm, writes at sample boundaries
  Intf intf;
  Ym2151 chip(intf);
  std::vector<uint16_t> reg_eg;
  chip.reset();
  std::vector<int16_t> rl, rr;
  rl.reserve(nsamp); rr.reserve(nsamp);
  size_t wi = 0;
  for (long k = 0; k < nsamp; k++) {
    // writes with ceil(t * rate) <= k land before sample k
    while (wi < w.size() && (long)std::ceil(w[wi].t * rate) <= k) {
      if (w[wi].a0) chip.write_data(w[wi].data); else chip.write_address(w[wi].data);
      wi++;
    }
    ymfm::ym2151::output_data o;
    chip.generate(&o, 1);
    if (egout) reg_eg.push_back(chip.fm().debug_operator(0)->debug_eg_attenuation());
    rl.push_back((int16_t)o.data[0]); rr.push_back((int16_t)o.data[1]);
  }

  // jt51: one sim step = one phiM clock (cen every step), cen_p1 every other
  Vjt51 *ym = new Vjt51;
  ym->rst = 1; ym->cs_n = 1; ym->wr_n = 1; ym->a0 = 0; ym->din = 0; ym->cen = 1; ym->cen_p1 = 0;
  for (int i = 0; i < 64; i++) { ym->cen_p1 = i & 1; ym->clk = 0; ym->eval(); ym->clk = 1; ym->eval(); }
  ym->rst = 0;
  std::vector<int16_t> jl, jr;
  std::vector<uint16_t> jeg(32, 0x3ff);
  FILE *fe = egout ? fopen(egout, "w") : nullptr;
  jl.reserve(nsamp + 8); jr.reserve(nsamp + 8);
  wi = 0;
  long phim = 0;
  const double phim_rate = 4000000.0;
  int pending = -1;   // write being presented
  while ((long)jl.size() < nsamp + 4) {
    bool p1 = (phim & 1);
    if (p1 && pending < 0 && wi < w.size() && (long)std::ceil(w[wi].t * rate) * 64 + shift <= phim) pending = (int)wi++;
    if (p1 && pending >= 0) { ym->cs_n = 0; ym->wr_n = 0; ym->a0 = w[pending].a0; ym->din = w[pending].data; }
    else { ym->cs_n = 1; ym->wr_n = 1; }
    ym->cen_p1 = p1;
    ym->clk = 0; ym->eval(); ym->clk = 1; ym->eval();
    if (p1 && pending >= 0) pending = -1;
    if (fe && p1) jeg[ym->rootp->jt51__DOT__cycles & 31] = ym->rootp->jt51__DOT__eg_XI;
    if (ym->sample) {
      if (fe && jl.size() < reg_eg.size()) {
        fprintf(fe, "%zu %d", jl.size(), reg_eg[jl.size()]);
        for (int i = 0; i < 32; i++) fprintf(fe, " %d", jeg[i]);
        fputc('\n', fe);
      }
      jl.push_back((int16_t)ym->left); jr.push_back((int16_t)ym->right);
    }
    phim++;
  }
  (void)phim_rate;

  long best = 0, bestlag = 0;
  for (long lag = -64; lag <= 64; lag++) {
    long eq = 0;
    for (long k = 0; k < nsamp; k++) {
      long j = k + lag;
      if (j < 0 || j >= (long)jl.size()) continue;
      eq += (rl[k] == jl[j] && rr[k] == jr[j]);
    }
    if (eq > best) { best = eq; bestlag = lag; }
  }
  long diff = 0, nonzero = 0, first = -1, maxd = 0;
  for (long k = 0; k < nsamp; k++) {
    long j = k + bestlag;
    if (j < 0 || j >= (long)jl.size()) continue;
    if (rl[k] || rr[k]) nonzero++;
    if (rl[k] != jl[j] || rr[k] != jr[j]) {
      if (first < 0) first = k;
      diff++;
      maxd = std::max(maxd, (long)std::max(std::abs(rl[k] - jl[j]), std::abs(rr[k] - jr[j])));
    }
  }
  printf("lag %ld: %ld of %ld samples equal (%ld not silent in ymfm), %ld differ, first at %ld (%.4f s), largest difference %ld\n",
         bestlag, best, nsamp, nonzero, diff, first, first / rate, maxd);
  if (first >= 0)
    for (long k = first; k < first + 8 && k < nsamp; k++)
      printf("  %ld: ymfm %6d %6d  jt51 %6d %6d\n", k, rl[k], rr[k], jl[k + bestlag], jr[k + bestlag]);
  if (out) {
    std::string a = std::string(out) + "_ymfm.raw", b = std::string(out) + "_jt51.raw";
    FILE *fa = fopen(a.c_str(), "wb"), *fb = fopen(b.c_str(), "wb");
    for (long k = 0; k < nsamp; k++) { int16_t s[2] = {rl[k], rr[k]}; fwrite(s, 2, 2, fa); }
    for (size_t k = 0; k < jl.size(); k++) { int16_t s[2] = {jl[k], jr[k]}; fwrite(s, 2, 2, fb); }
    fclose(fa); fclose(fb);
  }
  delete ym;
  return 0;
}
