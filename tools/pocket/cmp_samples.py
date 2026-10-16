#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare two raw sample files over the length they share: a board's chip
against its reference (sim/z80/tb_z80 --out, tb_ddonpach --oki-samples against
sim/ym2151/tb_ym2151 --out or tools/pocket/oki_model.py --out).

    python3 -I tools/pocket/cmp_samples.py A B [--type i16|i32] [--channels N]

Prints how many frames are equal, how many are not silent, and the first
that differs with the frames after it.
"""

import argparse
import array
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--type", default="i16", choices=["i16", "i32"])
    ap.add_argument("--channels", type=int, default=1)
    x = ap.parse_args()
    code = "h" if x.type == "i16" else "i"
    sa, sb = array.array(code), array.array(code)
    with open(x.a, "rb") as f:
        sa.frombytes(f.read())
    with open(x.b, "rb") as f:
        sb.frombytes(f.read())
    if sys.byteorder != "little":
        sa.byteswap()
        sb.byteswap()
    ch = x.channels
    n = min(len(sa), len(sb)) // ch
    first, diff, loud = -1, 0, 0
    for k in range(n):
        fa = sa[k * ch:(k + 1) * ch]
        fb = sb[k * ch:(k + 1) * ch]
        if any(fa):
            loud += 1
        if fa != fb:
            diff += 1
            if first < 0:
                first = k
    print(f"{n - diff} of {n} frames equal ({loud} not silent in {x.a}), {diff} differ"
          + (f", the first at {first}" if first >= 0 else "")
          + f"; lengths {len(sa) // ch} and {len(sb) // ch}")
    if first >= 0:
        for k in range(first, min(first + 6, n)):
            print(f"  {k}: {list(sa[k * ch:(k + 1) * ch])}  {list(sb[k * ch:(k + 1) * ch])}")
    return 1 if diff else 0


if __name__ == "__main__":
    sys.exit(main())
