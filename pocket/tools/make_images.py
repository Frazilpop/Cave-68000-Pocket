#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Make the Pocket's two graphics for this core, in APF's raw format.

  dist/Cores/frazilpop.Cave 68000/icon.bin   36 x 36, "C6"
  dist/Platforms/_images/cave68000.bin   521 x 165, from art/cave68000-banner.png
                                           (drawn from the game's logo)

The banner PNG must be 521 x 165, 8-bit greyscale, and is kept as the
natural picture; it goes in inverted (255 - v). Stored as it was, it showed
as a negative on the Pocket (Mille Miglia, 10 Oct 2026), so the stored byte
is ink, not brightness, whatever the templates suggest. Without the PNG, the
banner falls back to the title and the maker in the 5x7 font.

Format (Analogue: Packaging a Core, Graphical Asset Formats): 16 bits per
pixel, brightness in the upper byte, stored rotated 90 degrees
counter-clockwise. Analogue's own template icon settles the two details the
page leaves open, and is copied: words are big-endian (0xFF00 = bytes FF 00),
and the background is ON with the drawing OFF. The OS recolours the image
either way round.

Run from anywhere: python3 pocket/tools/make_images.py
"""
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(HERE, "..", "dist")
CORE = "frazilpop.Cave 68000"
PLATFORM = "cave68000"
BANNER = os.path.join(HERE, "..", "art", PLATFORM + "-banner.png")
ICON_TEXT = "C6"
# the fallback banner's two lines, when there is no PNG yet
LINE1 = "CAVE 68000"
LINE2 = "CAVE 1997"

# 5x7 glyphs, one string per row, '#' = ink.
FONT = {
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", "####."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "C": [".####", "#....", "#....", "#....", "#....", "#....", ".####"],
    "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "N": ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
    "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
    "'": [".##..", "..#..", ".#...", ".....", ".....", ".....", "....."],
    "&": [".##..", "#..#.", "#..#.", ".##..", "#.#.#", "#..#.", ".##.#"],
    ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
    "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
    " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
}


def text_width(s, scale):
    return (len(s) * 6 - 1) * scale


def draw_text(canvas, s, x0, y0, scale):
    for i, ch in enumerate(s):
        glyph = FONT.get(ch, FONT[" "])
        for gy, row in enumerate(glyph):
            for gx, c in enumerate(row):
                if c != "#":
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        canvas[y0 + gy * scale + dy][x0 + (i * 6 + gx) * scale + dx] = 0


def fit_scale(s, width, biggest):
    """The largest glyph scale (down to 1) at which s fits in width pixels."""
    return max(1, min(biggest, width // max(1, len(s) * 6 - 1)))


def blank(w, h):
    """A canvas of brightness bytes, background ON as in the template."""
    return [[0xFF] * w for _ in range(h)]


def read_png(path):
    """Rows of brightness bytes from an 8-bit greyscale, non-interlaced PNG."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    pos, idat = 8, b""
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if (depth, colour, interlace) != (8, 0, 0):
                raise SystemExit(f"{path}: must be 8-bit greyscale, not interlaced")
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    rows, prev = [], bytes(w)
    for y in range(h):
        filt, line = raw[y * (w + 1)], bytearray(raw[y * (w + 1) + 1:(y + 1) * (w + 1)])
        for x in range(w):
            a = line[x - 1] if x else 0
            b, c = prev[x], prev[x - 1] if x else 0
            if filt == 1:
                line[x] = (line[x] + a) & 0xFF
            elif filt == 2:
                line[x] = (line[x] + b) & 0xFF
            elif filt == 3:
                line[x] = (line[x] + (a + b) // 2) & 0xFF
            elif filt == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        rows.append(list(line))
        prev = line
    return rows


def save(canvas, path):
    """Rotate 90 degrees counter-clockwise and write 16-bit big-endian words."""
    h, w = len(canvas), len(canvas[0])
    out = bytearray()
    for r in range(w):                 # stored row r = original column w-1-r
        x = w - 1 - r
        for y in range(h):             # stored column = original row
            out += bytes((canvas[y][x], 0))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(out)
    print(f"{path}: {w}x{h}, {len(out)} bytes")


def main():
    # Core icon: 36 x 36, drawn at the 2x2 pixel scale Analogue recommends.
    icon = blank(36, 36)
    s, sc = ICON_TEXT, 2
    draw_text(icon, s, (36 - text_width(s, sc)) // 2, (36 - 7 * sc) // 2, sc)
    save(icon, os.path.join(DIST, "Cores", CORE, "icon.bin"))

    # Platform image: 521 x 165, the banner art when it is there.
    W, H = 521, 165
    if os.path.exists(BANNER):
        img = read_png(BANNER)
        if (len(img[0]), len(img)) != (W, H):
            raise SystemExit(f"{BANNER}: must be {W} x {H}")
        img = [[0xFF - v for v in row] for row in img]   # shown inverted otherwise
        save(img, os.path.join(DIST, "Platforms", "_images", PLATFORM + ".bin"))
        return
    img = blank(W, H)
    s1, s2 = fit_scale(LINE1, W - 40, 8), fit_scale(LINE2, W - 40, 3)
    h1, h2, gap = 7 * s1, 7 * s2, 18
    top = (H - (h1 + gap + h2)) // 2
    draw_text(img, LINE1, (W - text_width(LINE1, s1)) // 2, top, s1)
    draw_text(img, LINE2, (W - text_width(LINE2, s2)) // 2, top + h1 + gap, s2)
    save(img, os.path.join(DIST, "Platforms", "_images", PLATFORM + ".bin"))


if __name__ == "__main__":
    main()
