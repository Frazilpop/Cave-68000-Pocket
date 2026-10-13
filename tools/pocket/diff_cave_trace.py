#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core, Analogue Pocket port — Copyright (C) 2026 alphanu1
# Adapted for Cave 68000: this board's ROM window and maps.
"""Diff a 68000 bus trace against MAME's on this board (or census one).

    python3 -I tools/pocket/diff_cave_trace.py ours.txt build/mame/ddonpach_bus.txt ddonpach
    python3 -I tools/pocket/diff_cave_trace.py --census build/mame/ddonpach_bus.txt ddonpach

Both traces are in tools/mame_cave_bus_trace.lua's format, one access a line
(addr R|W data mask); '#' lines are skipped.

WHY NOT LINE BY LINE

fx68k reproduces the 68000's prefetch; MAME's core models it differently and
re-reads the same word in places fx68k does not, so a raw diff drowns within
a dozen lines. What is architecturally determined, and so must agree exactly,
is compared, in order:

  * every WRITE — a write is never speculative;
  * every READ outside the program ROM (000000-0fffff) — RAM and I/O reads
    the program asked for;
  * every read of the vector table (000000-0003ff): the reset vectors, and
    each interrupt's autovector fetch at 000064 (level 1, the only one this
    board raises), so the first divergence names the interrupt that caused
    it. (The boot's ROM checksum reads the table too, a byte at a time, in
    the same order on both sides.)

Lanes are masked: data is compared only where the mask says the 68000 drove
or took it. The region names are the game's map (cave.cpp), per game.
"""

import sys
from collections import Counter

ROM_END = 0x100000
VECTORS_END = 0x000400


def load(path):
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) != 4 or p[0].startswith("#"):
                continue
            out.append((int(p[0], 16), p[1], int(p[2], 16), int(p[3], 16)))
    return out


def fmt(rec):
    a, rw, d, m = rec
    lane = {0xffff: "w", 0xff00: "hi", 0x00ff: "lo"}.get(m, f"{m:04x}")
    return f"{a:06x} {rw} {d:04x} .{lane}"


# The maps, transcribed from cave.cpp (MAME 344d163) — a per-game fact, so a
# per-game table.
COMMON = [
    (0x000000, 0x000400, "vectors   000000-0003ff"),
    (0x400000, 0x410000, "spriteram 400000-40ffff"),
    (0x500000, 0x508000, "layer0    500000-507fff"),
]
DDONPACH_MAP = COMMON + [
    (0x100000, 0x110000, "work ram  100000-10ffff"),
    (0x300000, 0x300004, "ymz280b   300000-300003"),
    (0x600000, 0x608000, "layer1    600000-607fff"),
    (0x700000, 0x710000, "layer2    700000-70ffff (8x8, 4000 mirrored)"),
    (0x800000, 0x800008, "irq cause 800000-800007"),
    (0x800008, 0x800080, "videoregs 800008-80007f"),
    (0x900000, 0x900006, "layer0 r  900000-900005"),
    (0xa00000, 0xa00006, "layer1 r  a00000-a00005"),
    (0xb00000, 0xb00006, "layer2 r  b00000-b00005"),
    (0xc00000, 0xc10000, "palette   c00000-c0ffff"),
    (0xd00000, 0xd00002, "IN0       d00000"),
    (0xd00002, 0xd00004, "IN1+eeprm d00002"),
    (0xe00000, 0xe00002, "eeprom w  e00000"),
]
ESPRADE_MAP = [(0x700000, 0x708000, "layer2    700000-707fff") if lo == 0x700000 else (lo, hi, n)
               for lo, hi, n in DDONPACH_MAP]
GUWANGE_MAP = COMMON + [
    (0x200000, 0x210000, "work ram  200000-20ffff"),
    (0x300000, 0x300008, "irq cause 300000-300007"),
    (0x300008, 0x300080, "videoregs 300008-30007f"),
    (0x600000, 0x608000, "layer1    600000-607fff"),
    (0x700000, 0x708000, "layer2    700000-707fff"),
    (0x800000, 0x800004, "ymz280b   800000-800003"),
    (0x900000, 0x900006, "layer0 r  900000-900005"),
    (0xa00000, 0xa00006, "layer1 r  a00000-a00005"),
    (0xb00000, 0xb00006, "layer2 r  b00000-b00005"),
    (0xc00000, 0xc10000, "palette   c00000-c0ffff"),
    (0xd00010, 0xd00012, "IN0+eeprm d00010 (eeprom w d00011)"),
    (0xd00012, 0xd00014, "IN1+eeprm d00012"),
]
DFEVERON_MAP = COMMON + [
    (0x100000, 0x110000, "work ram  100000-10ffff"),
    (0x300000, 0x300004, "ymz280b   300000-300003"),
    (0x600000, 0x608000, "layer1    600000-607fff"),
    (0x708000, 0x709000, "palette   708000-708fff"),
    (0x710000, 0x710c00, "?         710000-710bff (read-only)"),
    (0x710c00, 0x711000, "?         710c00-710fff"),
    (0x800000, 0x800008, "irq cause 800000-800007"),
    (0x800008, 0x800080, "videoregs 800008-80007f"),
    (0x900000, 0x900006, "layer0 r  900000-900005"),
    (0xa00000, 0xa00006, "layer1 r  a00000-a00005"),
    (0xb00000, 0xb00002, "IN0       b00000"),
    (0xb00002, 0xb00004, "IN1+eeprm b00002"),
    (0xc00000, 0xc00002, "eeprom w  c00000"),
]
UOPOKO_MAP = COMMON + [
    (0x100000, 0x110000, "work ram  100000-10ffff"),
    (0x300000, 0x300004, "ymz280b   300000-300003"),
    (0x600000, 0x600008, "irq cause 600000-600007"),
    (0x600008, 0x600080, "videoregs 600008-60007f"),
    (0x700000, 0x700006, "layer0 r  700000-700005"),
    (0x800000, 0x810000, "palette   800000-80ffff"),
    (0x900000, 0x900002, "IN0       900000"),
    (0x900002, 0x900004, "IN1+eeprm 900002"),
    (0xa00000, 0xa00002, "eeprom w  a00000"),
]
GAIA_MAP = COMMON + [
    (0x100000, 0x110000, "work ram  100000-10ffff"),
    (0x300000, 0x300004, "ymz280b   300000-300003"),
    (0x508000, 0x510000, "layer0 +  508000-50ffff (RAM)"),
    (0x600000, 0x608000, "layer1    600000-607fff"),
    (0x608000, 0x610000, "layer1 +  608000-60ffff (RAM)"),
    (0x700000, 0x708000, "layer2    700000-707fff"),
    (0x708000, 0x710000, "layer2 +  708000-70ffff (RAM)"),
    (0x800000, 0x800008, "irq cause 800000-800007"),
    (0x800008, 0x800080, "videoregs 800008-80007f"),
    (0x900000, 0x900006, "layer0 r  900000-900005"),
    (0xa00000, 0xa00006, "layer1 r  a00000-a00005"),
    (0xb00000, 0xb00006, "layer2 r  b00000-b00005"),
    (0xc00000, 0xc10000, "palette   c00000-c0ffff"),
    (0xd00010, 0xd00012, "IN0       d00010 (coin counter w d00011)"),
    (0xd00012, 0xd00014, "IN1       d00012"),
    (0xd00014, 0xd00016, "DSW/wdog  d00014"),
]
MAP_OF = {}
for sets, m in ((("ddonpach", "ddonpachj"), DDONPACH_MAP),
                (("esprade", "espradej", "espradejo"), ESPRADE_MAP),
                (("guwange", "guwanges"), GUWANGE_MAP),
                (("feversos", "dfeveron"), DFEVERON_MAP),
                (("uopoko", "uopokoj"), UOPOKO_MAP),
                (("gaia", "theroes", "theroesa"), GAIA_MAP)):
    MAP_OF.update({s: m for s in sets})


def region_for(setname):
    if setname not in MAP_OF:
        raise SystemExit(f"no map for {setname!r}; known: {', '.join(MAP_OF)}")
    windows = MAP_OF[setname]

    def region(a):
        for lo, hi, name in windows:
            if lo <= a < hi:
                return name
        if a < ROM_END:
            return "rom       000400-0fffff"
        return f"OTHER     {a & 0xff0000:06x}"
    return region


def keep(r):
    return r[1] == "W" or r[0] >= ROM_END or r[0] < VECTORS_END


def census(path, setname):
    region = region_for(setname)
    recs = load(path)
    c = Counter((region(r[0]), r[1]) for r in recs)
    print(f"  {path}: {len(recs)} accesses, {sum(1 for r in recs if keep(r))} compared")
    for (k, rw), v in sorted(c.items()):
        print(f"  {k:<40} {rw} {v:8d}")
    return 0


def diff(ours, mame, setname):
    region = region_for(setname)
    a_all, m_all = load(ours), load(mame)
    if not a_all or not m_all:
        print(f"empty trace: ours={len(a_all)} mame={len(m_all)}", file=sys.stderr)
        return 2
    a, m = [r for r in a_all if keep(r)], [r for r in m_all if keep(r)]
    print(f"  ours {len(a_all):8d} accesses, {len(a):8d} compared")
    print(f"  mame {len(m_all):8d} accesses, {len(m):8d} compared")
    n = min(len(a), len(m))
    first = None
    for i in range(n):
        aa, mm = a[i], m[i]
        if aa[0] != mm[0] or aa[1] != mm[1] or aa[3] != mm[3] or \
                (aa[2] & aa[3]) != (mm[2] & mm[3]):
            first = i
            break
    if first is None:
        print(f"  MATCH over all {n} compared accesses")
    else:
        print(f"\n  FIRST DIVERGENCE at compared access {first} ({region(m[first][0]).strip()})")
        print(f"  {'ours':<22} {'mame':<22}")
        for i in range(max(0, first - 6), min(n, first + 7)):
            print(f"  {fmt(a[i]):<22} {fmt(m[i]):<22} {'<<' if i == first else '  '}")
    ca = Counter(region(r[0]) for r in a_all)
    cm = Counter(region(r[0]) for r in m_all)
    print(f"\n  {'region':<40}     ours     mame")
    for k in sorted(set(ca) | set(cm)):
        flag = "  <- one side only" if (k not in ca) != (k not in cm) else ""
        print(f"  {k:<40} {ca.get(k, 0):8d} {cm.get(k, 0):8d}{flag}")
    return 0 if first is None else 1


def main():
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == "--census":
        return census(args[1], args[2])
    if len(args) == 3:
        return diff(*args)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
