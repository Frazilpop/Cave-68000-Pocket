#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Cave 68000 for Analogue Pocket: random YM2151 register logs, in
# tools/mame_cave_z80.lua's format, for sim/ym2151's tb_ym2151 – every part
# of the chip played, where the two games' music plays only what it uses:
# random voices on all eight channels (every algorithm, feedback, DT1, DT2,
# MUL, KS, AMS-EN, every rate and level), the LFO's four waves at random
# rates and depths with PMS and AMS on, the LFO held in reset now and then
# (test register bit 1), the noise on channel 7, key codes changed under
# held notes, and keys turned on and off, one operator or several at a time.
# The timers are left alone (the reference has none; the play logs check
# them against MAME's status reads).
#
#   python3 -I sim/ym2151/fuzz.py <out.txt> [--seed N] [--seconds S]
import argparse
import random

ap = argparse.ArgumentParser()
ap.add_argument("out")
ap.add_argument("--seed", type=int, default=1)
ap.add_argument("--seconds", type=float, default=20.0)
args = ap.parse_args()
rnd = random.Random(args.seed)

Z80 = 8_000_000
out = []
tick = Z80 // 100          # start at 10 ms


def w(reg, val):
    """An address write and a data write, the data write 20-40 us after the last."""
    global tick
    out.append("%.12f Z W 50 %02x" % (tick / Z80, reg))
    tick += 11 + rnd.randrange(8)
    out.append("%.12f Z W 51 %02x" % (tick / Z80, val & 0xff))
    tick += 160 + rnd.randrange(160)


def voice(ch):
    w(0x20 + ch, rnd.choice((0x40, 0x80, 0xc0, 0xc0, 0xc0)) | rnd.randrange(64))
    w(0x28 + ch, rnd.randrange(128))
    w(0x30 + ch, rnd.randrange(64) << 2)
    w(0x38 + ch, rnd.randrange(128) if rnd.random() < 0.6 else 0)
    for op in range(4):
        s = ch + 8 * op
        w(0x40 + s, rnd.randrange(128))
        w(0x60 + s, rnd.choice((rnd.randrange(128), rnd.randrange(40))))
        w(0x80 + s, (rnd.randrange(4) << 6) | rnd.randrange(32))
        w(0xa0 + s, (rnd.randrange(2) << 7) | rnd.randrange(32))
        w(0xc0 + s, (rnd.randrange(4) << 6) | rnd.randrange(32))
        w(0xe0 + s, rnd.randrange(256))


def lfo():
    w(0x18, rnd.randrange(256))
    w(0x19, rnd.randrange(128))            # AMD
    w(0x19, 0x80 | rnd.randrange(128))     # PMD
    w(0x1b, rnd.randrange(4))


for ch in range(8):
    voice(ch)
lfo()
end = int(args.seconds * Z80)
while tick < end:
    r = rnd.random()
    if r < 0.45:
        w(0x08, (rnd.randrange(16) << 3) | rnd.randrange(8))
    elif r < 0.60:
        ch = rnd.randrange(8)
        w(0x28 + ch, rnd.randrange(128))
        w(0x30 + ch, rnd.randrange(64) << 2)
    elif r < 0.70:
        voice(rnd.randrange(8))
    elif r < 0.76:
        lfo()
    elif r < 0.80:
        w(0x0f, (rnd.randrange(2) << 7) | rnd.randrange(32))
    elif r < 0.82:
        w(0x01, 0x02)
        tick += rnd.randrange(Z80 // 50)
        w(0x01, 0x00)
    elif r < 0.92:
        s = rnd.randrange(32)
        w(rnd.choice((0x40, 0x60, 0x80, 0xa0, 0xc0, 0xe0)) + s, rnd.randrange(256))
    else:
        w(0x38 + rnd.randrange(8), rnd.randrange(128))
    tick += rnd.randrange(Z80 // 40)
open(args.out, "w").write("# fuzz %d\n" % args.seed + "\n".join(out) + "\n")
