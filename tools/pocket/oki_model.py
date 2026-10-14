#!/usr/bin/env python3
# license:BSD-3-Clause
# copyright-holders:Mirko Buffoni,Aaron Giles,Andrew Gardner,Alex W. Jackson
#
# A port of MAME's okim6295.cpp, okiadpcm.cpp and nmk112.cpp (0.289), cut to
# what DonPachi uses and taken out of MAME's device framework; under MAME's
# licence for those files, BSD-3-Clause.
"""DonPachi's sound as MAME makes it: a log of the 68000's accesses
(tools/mame_cave_oki.lua) played back through MAME's OKI M6295s and NMK112,
ported, on the samples of the set's .rom image.

    python3 -I tools/pocket/oki_model.py build/mame/oki/donpachi.txt \\
        build/pocket/donpachi.rom --out build/mame/oki/donpachi_model \\
        [--wav build/mame/oki/donpachi_model.wav] [--lazy-banks]

What it ports (MAME 0.289: okim6295.cpp, okiadpcm.cpp, nmk112.cpp; cave.cpp's
donpachi machine):

  * the two chips' streams: OKI 0 on 4.220 MHz / 4, OKI 1 on 4.220 MHz / 2,
    pin 7 high, so a sample every 132 clocks; MAME makes the rates integers
    (clock() / divisor): 7,992 and 15,984 Hz. Before it takes an access at
    time t MAME brings the chip's stream up to sample floor(t * rate), so
    sample n is made with what was written before (n + 1) / rate.
  * a command: a byte with bit 7 picks a phrase; the next byte starts it on
    the voices in its top nibble that are not playing, at the volume in its
    low nibble, if the phrase's start is below its stop (the phrase table's
    18-bit addresses at phrase * 8); a byte without bit 7 (and no phrase
    pending) stops the voices in bits 3-6. A status read is 0xf0 | the
    voices playing.
  * a voice: a nibble a sample, high nibble first, through the OKI ADPCM
    (signal clamped to -2048..2047, step 0..48), times the volume; it stops
    after 2 * (stop - start + 1) nibbles.
  * the NMK112: eight bank registers, four a chip, each picking the 64 KB
    page for one quarter of the chip's 256 KB; OKI 1's phrase table (its
    first 1 KB) is paged too, a 256-byte quarter at a time, by the same
    registers (set_page_mask(1 << 0): OKI 0 not paged). The pages are
    data & 31 on OKI 0 (2 MB) and data & 63 on OKI 1, whose 48 pages MAME
    folds 48-63 onto 32-47 – the image's oki1 region holds the fold, so a
    page is page * 64 KB there.

A bank write does not bring the stream up to date in MAME (the banks are
the OKI's address map, not its ROM interface): the samples made later – at
the chip's next access, or at the sound manager's update every 20 ms of
machine time, whichever is first – read the new bank even if they fall
before the write. --lazy-banks plays that; without it a bank write takes
effect at its own time. The two agree as long as no voice is playing out of
a bank when it is switched.

Writes --out.0 and --out.1: each chip's samples, little-endian int32, the
sum over the voices of signal * volume (volume 0x20 = 0 dB; MAME's sample
is that / 32 / 2048). --wav: the two mixed as cave.cpp routes them (OKI 0 at
1.6, OKI 1 at 1.0) at OKI 1's rate, OKI 0's samples held for two, 16 bits.
Checks every status read in the log against the port and says how many
agreed.
"""

import argparse
import struct
import sys
import wave

RATES = (7992, 15984)
VOLUME = [0x20, 0x16, 0x10, 0x0b, 0x08, 0x06, 0x04, 0x03, 0x02, 0, 0, 0, 0, 0, 0, 0]
INDEX_SHIFT = [-1, -1, -1, -1, 2, 4, 6, 8]
NBL2BIT = [[1, 0, 0, 0], [1, 0, 0, 1], [1, 0, 1, 0], [1, 0, 1, 1],
           [1, 1, 0, 0], [1, 1, 0, 1], [1, 1, 1, 0], [1, 1, 1, 1],
           [-1, 0, 0, 0], [-1, 0, 0, 1], [-1, 0, 1, 0], [-1, 0, 1, 1],
           [-1, 1, 0, 0], [-1, 1, 0, 1], [-1, 1, 1, 0], [-1, 1, 1, 1]]
DIFF = []
for step in range(49):
    stepval = int(16.0 * pow(11.0 / 10.0, step))      # floor: positive
    for nib in range(16):
        b = NBL2BIT[nib]
        DIFF.append(b[0] * (stepval * b[1] + stepval // 2 * b[2] + stepval // 4 * b[3] + stepval // 8))

OKI0_BASE, OKI1_BASE = 0x080080, 0x280080       # build_rom.py's donpachi layout


class Voice:
    __slots__ = ("playing", "base", "sample", "count", "volume", "signal", "step")

    def __init__(self):
        self.playing = False
        self.base = self.sample = self.count = self.volume = 0
        self.signal = self.step = 0


class Chip:
    def __init__(self, idx, rom, banks):
        self.idx = idx
        self.rom = rom
        self.banks = banks              # the NMK112's eight registers (shared list)
        self.rate = RATES[idx]
        self.voices = [Voice() for _ in range(4)]
        self.command = -1
        self.made = 0                   # samples made so far
        self.out = []

    def read_byte(self, addr, banks=None):
        b = banks or self.banks
        addr &= 0x3ffff
        q = addr >> 16
        if self.idx == 0:
            return self.rom[OKI0_BASE + ((b[q] & 31) << 16) + (addr & 0xffff)]
        if addr < 0x400:                # OKI 1's phrase table, paged by quarter
            page = b[4 + ((addr >> 8) & 3)] & 63
        else:
            page = b[4 + q] & 63
        return self.rom[OKI1_BASE + (page << 16) + (addr & 0xffff)]

    def update(self, t, banks=None):
        target = int(t * self.rate)      # floor(t * rate) samples made by t
        while self.made < target:
            acc = 0
            for v in self.voices:
                if not v.playing:
                    continue
                byte = self.read_byte(v.base + v.sample // 2, banks)
                nib = (byte >> (0 if v.sample & 1 else 4)) & 15
                v.signal += DIFF[v.step * 16 + nib]
                v.signal = 2047 if v.signal > 2047 else (-2048 if v.signal < -2048 else v.signal)
                v.step += INDEX_SHIFT[nib & 7]
                v.step = 48 if v.step > 48 else (0 if v.step < 0 else v.step)
                acc += v.signal * v.volume
                v.sample += 1
                if v.sample >= v.count:
                    v.playing = False
            self.out.append(acc)
            self.made += 1

    def status(self):
        return 0xf0 | sum(1 << i for i, v in enumerate(self.voices) if v.playing)

    def write(self, data):
        if self.command != -1:
            mask = data >> 4
            for i, v in enumerate(self.voices):
                if not (mask >> i) & 1 or v.playing:
                    continue
                base = self.command * 8
                start = (self.read_byte(base) << 16 | self.read_byte(base + 1) << 8 | self.read_byte(base + 2)) & 0x3ffff
                stop = (self.read_byte(base + 3) << 16 | self.read_byte(base + 4) << 8 | self.read_byte(base + 5)) & 0x3ffff
                if start < stop:
                    v.playing = True
                    v.base = start
                    v.sample = 0
                    v.count = 2 * (stop - start + 1)
                    v.signal = v.step = 0
                    v.volume = VOLUME[data & 15]
            self.command = -1
        elif data & 0x80:
            self.command = data & 0x7f
        else:
            mask = data >> 3
            for i, v in enumerate(self.voices):
                if (mask >> i) & 1:
                    v.playing = False


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("log")
    ap.add_argument("rom")
    ap.add_argument("--out", help="write OUT.0 and OUT.1, each chip's samples (int32)")
    ap.add_argument("--wav")
    ap.add_argument("--lazy-banks", action="store_true",
                    help="a bank write waits for the chip's next access, as in MAME")
    a = ap.parse_args()

    rom = open(a.rom, "rb").read()
    banks = [0] * 8
    pending = [0] * 8                   # --lazy-banks: written, not yet seen by each chip
    chips = [Chip(0, rom, banks), Chip(1, rom, banks)]
    seen = [list(banks), list(banks)]   # the banks each chip's next update reads
    end_t = 0.0
    ok = bad = 0
    next20 = 1                          # --lazy-banks: the next 20 ms update, in updates
    for line in open(a.log):
        if a.lazy_banks and not line.startswith("#"):
            t = float(line.split()[0])
            while next20 * 0.02 <= t:
                for c in chips:
                    c.update(next20 * 0.02)
                next20 += 1
        if line.startswith("#"):
            if line.startswith("# frame"):
                end_t = float(line.split()[3])
            continue
        f = line.split()
        t, kind = float(f[0]), f[1]
        end_t = t
        if kind == "N":
            off, data = int(f[2]), int(f[3], 16)
            if not a.lazy_banks:
                for c in chips:
                    c.update(t)
            banks[off] = data
            continue
        c = chips[int(f[2])]
        if a.lazy_banks:
            c.update(t, banks)
        else:
            c.update(t)
        if kind == "W":
            c.write(int(f[3], 16))
        elif kind == "S":
            want, got = int(f[3], 16), c.status()
            if want == got:
                ok += 1
            else:
                bad += 1
                if bad <= 10:
                    print(f"  status at {t:.9f}: MAME {want:02x}, the port {got:02x}")
    for c in chips:
        c.update(end_t)
    print(f"{a.log}: {len(chips[0].out)} + {len(chips[1].out)} samples to {end_t:.3f} s; "
          f"status reads: {ok} agree, {bad} differ")

    if a.out:
        for c in chips:
            with open(f"{a.out}.{c.idx}", "wb") as fh:
                fh.write(struct.pack(f"<{len(c.out)}i", *c.out))
    if a.wav:
        s0, s1 = chips[0].out, chips[1].out
        frames = bytearray()
        for n in range(len(s1)):
            x0 = s0[n // 2] if n // 2 < len(s0) else 0
            v = (x0 * 8) // 10 + s1[n] // 2
            v = max(-32768, min(32767, v))
            frames += struct.pack("<h", v)
        with wave.open(a.wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATES[1])
            w.writeframes(bytes(frames))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
