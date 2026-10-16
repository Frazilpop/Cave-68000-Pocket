#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare two sound-board logs (tools/mame_cave_z80.lua's format) access for
access: MAME's against the board's own (sim/ddonpach/tb_ddonpach --z80-log,
sim/z80/tb_z80 --log).

    python3 -I tools/pocket/diff_z80_log.py MAME.txt BOARD.txt [--kinds ZC]
        [--seconds S] [--context N]

--kinds picks the lines compared, each kind on its own: Z the Z80's I/O
ports, M its memory at 4000-ffff (both logs need it), C the 68000's
accesses at b8006c-b8006f (its writes to b8006c are video registers and are
left out). For each kind: how many lines are equal in order (direction,
address, data) up to the first that differs, that one with the lines
before it, and how far the equal ones' times are off MAME's, in 32 MHz
clocks.
"""

import argparse
import collections
import sys

CLOCK = 32e6


def read(path, kinds, seconds):
    out = {k: [] for k in kinds}
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                continue
            p = line.split()
            if len(p) < 5 or p[1] not in out:
                continue
            t = float(p[0])
            if t > seconds:
                continue
            if p[1] == "C" and p[2] == "W" and p[3] == "b8006c":
                continue
            out[p[1]].append((t, p[2], int(p[3], 16), int(p[4], 16)))
    for k in out:
        out[k].sort(key=lambda a: a[0])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("mame")
    ap.add_argument("board")
    ap.add_argument("--kinds", default="ZC")
    ap.add_argument("--seconds", type=float, default=1e9)
    ap.add_argument("--context", type=int, default=6)
    a = ap.parse_args()
    m = read(a.mame, a.kinds, a.seconds)
    b = read(a.board, a.kinds, a.seconds)
    bad = 0
    for k in a.kinds:
        mm, bb = m[k], b[k]
        n = min(len(mm), len(bb))
        first = None
        offs = collections.Counter()
        for i in range(n):
            if mm[i][1:] != bb[i][1:]:
                first = i
                break
            offs[round((bb[i][0] - mm[i][0]) * CLOCK)] += 1
        eq = n if first is None else first
        print(f"{k}: {eq} of {len(mm)} equal in order (the board made {len(bb)})"
              + ("" if first is None else f", the first to differ {first}"))
        on = offs.get(0, 0)
        off = sorted(((d, c) for d, c in offs.items() if d), key=lambda x: -x[1])[:10]
        print(f"   on MAME's clock {on}, off it {eq - on}" + ("" if not off else ": " +
              " ".join(f"{d:+d} x{c}" for d, c in off)))
        if first is not None:
            bad += 1
            lo = max(0, first - a.context)
            for i in range(lo, min(first + a.context, len(mm))):
                print(f"   MAME  {mm[i][0]:.9f} {mm[i][1]} {mm[i][2]:04x} {mm[i][3]:02x}" + ("   <-" if i == first else ""))
            for i in range(lo, min(first + a.context, len(bb))):
                print(f"   board {bb[i][0]:.9f} {bb[i][1]} {bb[i][2]:04x} {bb[i][3]:02x}" + ("   <-" if i == first else ""))
        elif len(mm) != len(bb):
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
