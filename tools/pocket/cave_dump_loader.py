#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build a program ROM that loads a MAME dump into the board, for the harness.

    python3 -I tools/pocket/cave_dump_loader.py DUMPDIR OUT.bin [--mame-budget]

DUMPDIR is one frame of tools/mame_cave_dump.lua (f<NNNNN>/ with frame.json).
OUT.bin replaces the program region of the set's image (tb_ddonpach --prog):
a 68000 program that copies the dumped state into the board through its own
bus, at the addresses cave.cpp maps for the set, then spins at LOADED_PC.
The harness sees the fetch there, presses pause (the board halts the 68000
and swaps the sprite frame buffer at every vblank, so the 013 keeps drawing
the loaded list) and captures a picture a few frames later.

What goes where, for picture N (the dump script's "which frame is which"):
  palette.bin, layer<k>_vram16 / _line / _vram8 / _regs   the state picture
      N's layers were drawn from (live at notifier N);
  spriteram_at_draw.bin, videoregs_at_draw.bin            the list and the
      013's registers as it drew picture N's sprites, with videoregs[4]'s
      bank bits set to the bank MAME drew (sprite_bank_drawn).
The scratch RAM is not shown, so it is not loaded.

--mame-budget clears the entries MAME's 013 never reached: sprite013 charges
32 clocks an entry plus the source pixels (every sized entry on the zoom
format, on-screen ones only on ddonpach's and donpachi's) against 448 x 272
x 2 and stops
drawing when they run out (as tools/mame_cave_sprite_load.lua models it).
The board has no such budget; with the list cut where MAME's ran out, a
frame MAME cut must match too. Going through the bus
means every game's address decode is the board's own.

Reads derived dumps only, never the ROMs.
"""

import json
import os
import struct
import sys

# cave.cpp's maps (MAME 344d163): layer windows, layer control, the 013's
# registers, sprite RAM, palette.
MAP_A = dict(layers=[0x500000, 0x600000, 0x700000],
             lregs=[0x900000, 0xA00000, 0xB00000],
             vregs=0x800000, sprites=0x400000, palette=0xC00000)
MAPS = {
    "ddonpach": MAP_A, "esprade": MAP_A, "gaia": MAP_A,
    "guwange": dict(MAP_A, vregs=0x300000),
    "uopoko": dict(layers=[0x500000], lregs=[0x700000], vregs=0x600000,
                   sprites=0x400000, palette=0x800000),
    "feversos": dict(layers=[0x500000, 0x600000], lregs=[0x900000, 0xA00000],
                     vregs=0x800000, sprites=0x400000, palette=0x708000),
    "donpachi": dict(layers=[0x300000, 0x200000, 0x400000], lregs=[0x700000, 0x600000, 0x800000],
                     vregs=0x900000, sprites=0x500000, palette=0xA08000, prog=0x80000),
}
PARENT = {"ddonpachj": "ddonpach", "espradej": "esprade", "espradejo": "esprade",
          "guwanges": "guwange", "uopokoj": "uopoko", "dfeveron": "feversos",
          "theroes": "gaia", "theroesa": "gaia",
          "donpachij": "donpachi", "donpachijs": "donpachi", "donpachikr": "donpachi",
          "donpachihk": "donpachi"}

ENTRY, LOADED_PC, TABLE, DATA = 0x000400, 0x000500, 0x001000, 0x002000
PROG_SIZE = 0x100000                # the program region (donpachi: 0x80000, MAPS' prog)

# The loader. a2 walks a table of (words, source, destination) longs, ended
# by a zero count; one word moved at a time, as the game itself writes.
CODE = bytes.fromhex(
    "45f9" + f"{TABLE:08x}"   # 400  lea     TABLE.l, a2
    "201a"                    # 406  move.l  (a2)+, d0
    "6700" "00f6"             # 408  beq.w   LOADED_PC
    "205a"                    # 40c  movea.l (a2)+, a0
    "225a"                    # 40e  movea.l (a2)+, a1
    "5380"                    # 410  subq.l  #1, d0
    "32d8"                    # 412  move.w  (a0)+, (a1)+
    "51c8" "fffc"             # 414  dbra    d0, 412
    "60ec")                   # 418  bra.s   406
SPIN = bytes.fromhex("60fe")  # 500  bra.s   500


MAX_CLK = 448 * 272 * 2


def sext10(v):
    v &= 0x3FF
    return v - 0x400 if v >= 0x200 else v


def budget_cut(ram, base, alt, vreg5, max_x, max_y):
    """The first entry of the list at word `base` that MAME's 013 never drew
    (1024 if it drew them all)."""
    clk = 0
    integer_pos = (vreg5 & 0x3000) == 0
    for i in range(1024):
        w = ram[base + 8 * i: base + 8 * i + 8]
        clk += 32
        if clk > MAX_CLK:
            return i
        if alt:
            attr, x, y, size, zx, zy = w[0], w[2], w[3], w[4], 0x100, 0x100
        else:
            x, y, attr, zx, zy, size = w[0], w[1], w[2], w[4], w[5], w[6]
        cols, rows = (size >> 8) & 0x1F, size & 0x1F
        if not cols or not rows:
            continue
        tw, th = cols * 16, rows * 16
        tot_w, tot_h = tw, th
        if alt:
            x, y = sext10(x), sext10(y)
        else:
            clk += tw * th                       # charged before the visibility test
            if clk > MAX_CLK:
                return i
            flipx, flipy = attr & 8, attr & 4
            tot_wf, tot_hf = tw * zx, th * zy
            tot_w, tot_h = tot_wf // 0x100, tot_hf // 0x100
            if integer_pos:
                x, y = (x & 0x3FF) << 8, (y & 0x3FF) << 8
            else:
                x, y = x << 2, y << 2
            if tot_w <= 1:
                x -= 0x80
            if tot_h <= 1:
                y -= 0x80
            if integer_pos:
                x, y = x >> 8, y >> 8
                if flipx and zx != 0x100:
                    x += tw - tot_w
                if flipy and zy != 0x100:
                    y += th - tot_h
            else:
                if flipx and zx != 0x100:
                    x += (tw << 8) - tot_wf - 0x80
                if flipy and zy != 0x100:
                    y += (th << 8) - tot_hf - 0x80
                x, y = x >> 8, y >> 8
            x, y = sext10(x), sext10(y)
        if alt and not (x + tot_w <= 0 or x >= max_x or y + tot_h <= 0 or y >= max_y):
            clk += tw * th                       # on-screen ones only
            if clk > MAX_CLK:
                return i
    return 1024


def words_le(path):
    data = open(path, "rb").read()
    return list(struct.unpack("<%dH" % (len(data) // 2), data))


def main():
    args = [a for a in sys.argv[1:] if a != "--mame-budget"]
    if len(args) != 2:
        sys.exit(__doc__)
    d, out = args
    budget = "--mame-budget" in sys.argv
    info = json.load(open(os.path.join(d, "frame.json")))
    s = info["set"]
    m = MAPS[PARENT.get(s, s)]
    bank = info.get("sprite_bank_drawn")
    if bank is None or not os.path.exists(os.path.join(d, "spriteram_at_draw.bin")):
        sys.exit(f"{d}: no sprite draw recorded for this frame (the boot runs with interrupts masked)")

    copies = []                                 # (destination, words)
    copies.append((m["palette"], words_le(os.path.join(d, "palette.bin"))))
    for k, base in enumerate(m["layers"]):
        p = lambda name: os.path.join(d, f"layer{k}_{name}.bin")
        if os.path.exists(p("vram16")):
            copies.append((base + 0x0000, words_le(p("vram16"))))
            copies.append((base + 0x1000, words_le(p("line"))))
            copies.append((base + 0x4000, words_le(p("vram8"))))
        else:                                   # vram_8x8_map: the 8 x 8 map alone
            copies.append((base, words_le(p("vram8"))))
        copies.append((m["lregs"][k], words_le(p("regs"))))
    sprites = words_le(os.path.join(d, "spriteram_at_draw.bin"))
    vregs = words_le(os.path.join(d, "videoregs_at_draw.bin"))[:8]
    cut = 1024
    if budget:
        base = bank * 0x2000
        cut = budget_cut(sprites, base, PARENT.get(s, s) in ("ddonpach", "donpachi"), vregs[5],
                         info["width"], info["height"])
        sprites[base + 8 * cut: base + 0x2000] = [0] * (0x2000 - 8 * cut)
    copies.append((m["sprites"], sprites))
    vregs[4] = (vregs[4] & ~3) | bank
    copies.append((m["vregs"], vregs))

    size = m.get("prog", PROG_SIZE)
    rom = bytearray(size)
    rom[0:8] = struct.pack(">II", 0, ENTRY)
    rom[ENTRY:ENTRY + len(CODE)] = CODE
    rom[LOADED_PC:LOADED_PC + len(SPIN)] = SPIN
    table, src = [], DATA
    for dst, w in copies:
        rom[src:src + 2 * len(w)] = struct.pack(">%dH" % len(w), *w)
        table.append(struct.pack(">III", len(w), src, dst))
        src += 2 * len(w)
    table.append(struct.pack(">I", 0))
    t = b"".join(table)
    assert TABLE + len(t) <= DATA and src <= size
    rom[TABLE:TABLE + len(t)] = t
    open(out, "wb").write(rom)
    print(f"{out}: {s} frame {info['frame']}, {len(copies)} copies, "
          f"{sum(len(w) for _, w in copies)} words, sprite bank {bank}"
          + (f", MAME's budget ran out at entry {cut}" if cut < 1024 else ""))


if __name__ == "__main__":
    main()
