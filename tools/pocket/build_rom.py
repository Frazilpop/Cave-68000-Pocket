#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core, Analogue Pocket port — Copyright (C) 2026 alphanu1
# Adapted for Cave 68000: this board's sets, regions and byte orders.
"""Build the Pocket's SDRAM image (<set>.rom) for the Cave 68000 board from MAME zips.

    python3 -I tools/pocket/build_rom.py ddonpach ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py all      ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py guwange  ~/Downloads build/roms --regions

THE CONTRACT is the layout each game's image follows (LAYOUT_ORDER and the
offsets OFFSETS asserts): the regions packed one after another in the order
the MiSTer core's MRAs concatenate them – program, EEPROM, samples, layer 0,
layer 1, layer 2, sprites – so every region starts where upstream's
CaveGameConfig expects it and the board's tables are untouched. One file per
set, no gaps, the size the regions add up to. The Pocket loads the file at
bridge address 0 and the shell writes byte n to SDRAM byte n.

Byte order within a region is the MRA's, which is how the board reads it:
  program   MAME's region order – even byte = the 68000 word's high byte
            (ROM_LOAD16_BYTE: the first file on even bytes, the second on odd)
  EEPROM    the zip's 128-byte file as it is (MAME: ROM_LOAD16_WORD)
  samples, layers   the files as they are, one after another
  sprites   the files as they are – ddonpach's are NOT word-swapped the way
            MAME's ROM_LOAD16_WORD_SWAP leaves its region; esprade's and
            guwange's pairs are byte-interleaved (file A on even bytes, file
            B on odd), not MAME's 32-bit word swap; guwange's second pair is
            there twice, as MAME's ROM_RELOAD and the MRA both have it.
verify_rom.py knows these permutations and checks every region against
MAME's own copy.

FILES ARE FOUND BY CRC32, NOT BY NAME OR PATH. A merged zip keeps a clone's
program ROMs under <clone>/; a split set keeps them in <clone>.zip. Every
zip in ZIPDIR is indexed (central directory only, nothing decompressed until
needed), the set's own zip and its parent's are preferred – a zip named
"ddonpach(1).zip", a browser's second download, counts as ddonpach.zip – and
a directory ZIPDIR/<set>/ of loose files is accepted too. Size and CRC must
both match; zipfile re-checks the CRC as it decompresses.

No patches: upstream's MRAs patch DoDonPachi's program past its ROM check
and the EEPROMs to enable the third button; MAME boots the sets as dumped,
and so does this core.

--regions writes OUTDIR/<set>_<region>.bin for every region, in the image's
byte order, for the Verilator harness.

This reads ROMs named on the command line and writes only where told –
build/ by convention, which is gitignored. No ROM data is baked in here.
"""

import argparse
import hashlib
import os
import re
import sys
import zipfile
import zlib

# --------------------------------------------------------------------- layout
# The regions in the image's order. A set without one (gaia and theroes have
# no EEPROM; uopoko has one layer, feversos two) simply skips it.
LAYOUT_ORDER = ["prog", "eeprom", "ymz", "layer0", "layer1", "layer2", "sprites"]

# Where upstream's CaveGameConfig expects each region, by game id: checked
# against the packing when an image is built, so a wrong size cannot pass.
OFFSETS = {
    1: {"ymz": 0x0100080, "layer0": 0x0500080, "layer1": 0x0700080, "layer2": 0x0900080, "sprites": 0x0b00080},  # ddonpach
    3: {"ymz": 0x0100080, "layer0": 0x0500080, "layer1": 0x0d00080, "layer2": 0x1500080, "sprites": 0x1900080},  # esprade
    5: {"ymz": 0x0100080, "layer0": 0x0500080, "layer1": 0x0d00080, "layer2": 0x1100080, "sprites": 0x1500080},  # guwange
    0: {"ymz": 0x0100080, "layer0": 0x0500080, "layer1": 0x0700080, "sprites": 0x0900080},                       # feversos
    4: {"ymz": 0x0100080, "layer0": 0x0300080, "sprites": 0x0700080},                                            # uopoko
    6: {"ymz": 0x0100000, "layer0": 0x0d00000, "layer1": 0x1100000, "layer2": 0x1500000, "sprites": 0x1900000},  # gaia
}

# ------------------------------------------------------------------ ROM_START
# Transcribed from cave.cpp's ROM_START blocks for the fourteen sets (CRCs
# and sizes), laid out as the MRAs concatenate them:
#
#   ("L", name, crc, offset, length)          the file as it is
#   ("B", name, crc, offset, length)          ROM_LOAD16_BYTE: file byte k -> offset + 2k
#   ("I", (nameA, crcA), (nameB, crcB), offset, length_each)
#                                             byte-interleaved pair: A[k] -> offset + 2k, B[k] -> offset + 2k + 1
#
# Region: (size, ops).


def L(n, c, o, s): return ("L", n, c, o, s)
def B(n, c, o, s): return ("B", n, c, o, s)
def I(a, b, o, s): return ("I", a, b, o, s)


def _prog(even, odd):
    return (0x100000, [B(even[0], even[1], 0x000000, 0x080000), B(odd[0], odd[1], 0x000001, 0x080000)])


def _eeprom(name, crc):
    return (0x80, [L(name, crc, 0, 0x80)])


# DoDonPachi: three layers (4bpp, 4bpp, 8bpp), 4bpp sprites without zoom.
def _ddonpach(prog, eeprom):
    return {
        "prog": _prog(*prog),
        "eeprom": _eeprom(*eeprom),
        "ymz": (0x400000, [L("u6.bin", 0x9dfdafaf, 0x000000, 0x200000),
                           L("u7.bin", 0x795b17d5, 0x200000, 0x200000)]),
        "layer0": (0x200000, [L("u60.bin", 0x903096a7, 0, 0x200000)]),
        "layer1": (0x200000, [L("u61.bin", 0xd89b7631, 0, 0x200000)]),
        "layer2": (0x200000, [L("u62.bin", 0x292bfb6b, 0, 0x200000)]),
        "sprites": (0x800000, [L("u50.bin", 0x14b260ec, 0x000000, 0x200000),
                               L("u51.bin", 0xe7ba8cce, 0x200000, 0x200000),
                               L("u52.bin", 0x02492ee0, 0x400000, 0x200000),
                               L("u53.bin", 0xcb4c10f0, 0x600000, 0x200000)]),
    }


# ESP Ra.De.: three 8bpp layers, 8bpp zoomed sprites in two byte-interleaved pairs.
def _esprade(prog):
    return {
        "prog": _prog(*prog),
        "eeprom": _eeprom("eeprom-esprade.bin", 0x315fb546),
        "ymz": (0x400000, [L("esp_u19.u19", 0xf54b1cab, 0, 0x400000)]),
        "layer0": (0x800000, [L("esp_u54.u54", 0xe7ca6936, 0x000000, 0x400000),
                              L("esp_u55.u55", 0xf53bd94f, 0x400000, 0x400000)]),
        "layer1": (0x800000, [L("esp_u52.u52", 0xe7abe7b4, 0x000000, 0x400000),
                              L("esp_u53.u53", 0x51a0f391, 0x400000, 0x400000)]),
        "layer2": (0x400000, [L("esp_u51.u51", 0x0b9b875c, 0, 0x400000)]),
        "sprites": (0x1000000, [I(("esp_u63.u63", 0x2f2fe92c), ("esp_u64.u64", 0x491a3da4), 0x000000, 0x400000),
                                I(("esp_u65.u65", 0x06563efe), ("esp_u66.u66", 0x7bbe4cfc), 0x800000, 0x400000)]),
    }


# Guwange: as ESP Ra.De.; the second sprite pair is loaded twice (ROM_RELOAD).
def _guwange(prog):
    return {
        "prog": _prog(*prog),
        "eeprom": _eeprom("eeprom-guwange.bin", 0xc3174959),
        "ymz": (0x400000, [L("u0462.bin", 0xb3d75691, 0, 0x400000)]),
        "layer0": (0x800000, [L("u101.bin", 0x0369491f, 0, 0x800000)]),
        "layer1": (0x400000, [L("u10102.bin", 0xe28d6855, 0, 0x400000)]),
        "layer2": (0x400000, [L("u10103.bin", 0x0fe91b8e, 0, 0x400000)]),
        "sprites": (0x2000000, [I(("u083.bin", 0xadc4b9c4), ("u082.bin", 0x3d75876c), 0x0000000, 0x800000),
                                I(("u086.bin", 0x188e4f81), ("u085.bin", 0xa7d5659e), 0x1000000, 0x400000),
                                I(("u086.bin", 0x188e4f81), ("u085.bin", 0xa7d5659e), 0x1800000, 0x400000)]),
    }


# Fever SOS / Dangun Feveron: two 4bpp layers, 4bpp zoomed sprites.
def _feversos(prog, eeprom):
    return {
        "prog": _prog(*prog),
        "eeprom": _eeprom(*eeprom),
        "ymz": (0x400000, [L("cv01-u19.bin", 0x5f5514da, 0, 0x400000)]),
        "layer0": (0x200000, [L("cv01-u50.bin", 0x7a344417, 0, 0x200000)]),
        "layer1": (0x200000, [L("cv01-u49.bin", 0xd21cdda7, 0, 0x200000)]),
        "sprites": (0x800000, [L("cv01-u25.bin", 0xa6f6a95d, 0x000000, 0x400000),
                               L("cv01-u26.bin", 0x32edb62a, 0x400000, 0x400000)]),
    }


# Puzzle Uo Poko: one 8bpp layer, 4bpp zoomed sprites.
def _uopoko(prog):
    return {
        "prog": _prog(*prog),
        "eeprom": _eeprom("eeprom-uopoko.bin", 0xf4a24b95),
        "ymz": (0x200000, [L("cave_cv-02_u4.u4", 0xa2d0d755, 0, 0x200000)]),
        "layer0": (0x400000, [L("cave_cv-02_u49.u49", 0x12fb11bb, 0, 0x400000)]),
        "sprites": (0x400000, [L("cave_cv-02_u33.u33", 0x5d142ad2, 0, 0x400000)]),
    }


# Gaia Crusaders and Thunder Heroes: three 8bpp layers, 4bpp zoomed sprites,
# 12 MB of samples, DIP switches and no EEPROM.
def _gaia(prog, snd3, bg, obj):
    return {
        "prog": _prog(*prog),
        "ymz": (0xc00000, [L(snd3[0][0], snd3[0][1], 0x000000, 0x400000),
                           L(snd3[1][0], snd3[1][1], 0x400000, 0x400000),
                           L(snd3[2][0], snd3[2][1], 0x800000, 0x400000)]),
        "layer0": (0x400000, [L(bg[0][0], bg[0][1], 0, 0x400000)]),
        "layer1": (0x400000, [L(bg[1][0], bg[1][1], 0, 0x400000)]),
        "layer2": (0x400000, [L(bg[2][0], bg[2][1], 0, 0x400000)]),
        "sprites": (0x800000, [L(obj[0][0], obj[0][1], 0x000000, 0x400000),
                               L(obj[1][0], obj[1][1], 0x400000, 0x400000)]),
    }


def _set(parent, game, regions):
    return {"parent": parent, "game": game, "regions": regions}


GAIA_SND = [("snd1.447", 0x92770a52), ("snd2.454", 0x329ae1cf), ("snd3.455", 0x4048d64e)]
GAIA_BG = [("bg1.989", 0x013a693d), ("bg2.995", 0x783cc62f), ("bg3.998", 0xbcd61d1c)]
GAIA_OBJ = [("obj1.736", 0xf4f84e5d), ("obj2.738", 0x15c2a9ce)]
THEROES_SND = [("crvsaders-snd1.u0447", 0x92770a52), ("crvsaders-snd2.u0454", 0x329ae1cf), ("t-hero-snd3.u0455", 0x52b0b2c0)]
THEROES_BG = [("t-hero-bg1.u0999", 0x47b0fb40), ("t-hero-bg2.u0995", 0xb16237a1), ("t-hero-bg3.u0998", 0x08eb5604)]
THEROES_OBJ = [("t-hero-obj1.u0736", 0x35090f7c), ("t-hero-obj2.u0738", 0x71605108)]

SETS = {
    # DoDonPachi (World, 1997 2/ 5 Master Ver.) and Japan
    "ddonpach":  _set(None, 1, _ddonpach((("b1.u27", 0xb5cdc8d3), ("b2.u26", 0x6bbb063a)), ("eeprom-ddonpach.bin", 0x315fb546))),
    "ddonpachj": _set("ddonpach", 1, _ddonpach((("u27.bin", 0x2432ff9b), ("u26.bin", 0x4f3a914a)), ("eeprom-ddonpach.bin", 0x315fb546))),
    # ESP Ra.De. (World 4/22 International), Japan 4/21 and 4/14 Master
    "esprade":   _set(None, 3, _esprade((("u42.int", 0x3b510a73), ("u41.int", 0x97c1b649)))),
    "espradej":  _set("esprade", 3, _esprade((("u42_ver.2", 0x75d03c42), ("u41_ver.2", 0x734b3ef0)))),
    "espradejo": _set("esprade", 3, _esprade((("u42.bin", 0x0718c7e5), ("u41.bin", 0xdef30539)))),
    # Guwange (Japan 1999 6/24 Master) and the 2000 7/7 Special Ver.
    "guwange":   _set(None, 5, _guwange((("gu-u0127.bin", 0xf86b5293), ("gu-u0129.bin", 0x6c0e3b93)))),
    "guwanges":  _set("guwange", 5, _guwange((("gu-u0127b.bin", 0x64667d2e), ("gu-u0129b.bin", 0xa99c6b6c)))),
    # Fever SOS (World 98/09/25) – MAME's parent – and Dangun Feveron (Japan 98/09/17)
    "feversos":  _set(None, 0, _feversos((("cv01-u34.sos", 0x24ef3ce6), ("cv01-u33.sos", 0x64ff73fd)), ("eeprom-feversos.bin", 0xd80303aa))),
    "dfeveron":  _set("feversos", 0, _feversos((("cv01-u34.bin", 0xbe87f19d), ("cv01-u33.bin", 0xe53a7db3)), ("eeprom-dfeveron.bin", 0xc3174959))),
    # Puzzle Uo Poko (World) and Japan
    "uopoko":    _set(None, 4, _uopoko((("u26.u26", 0xb445c9ac), ("u25.u25", 0xa1258482)))),
    "uopokoj":   _set("uopoko", 4, _uopoko((("u26j.u26", 0xe7eec050), ("u25j.u25", 0x68cb6211)))),
    # Gaia Crusaders; Thunder Heroes sets 1 and 2
    "gaia":      _set(None, 6, _gaia((("prg1.127", 0x47b904b2), ("prg2.128", 0x469b7794)), GAIA_SND, GAIA_BG, GAIA_OBJ)),
    "theroes":   _set(None, 6, _gaia((("t-hero-epm1.u0127", 0x09db7195), ("t-hero-epm0.u0129", 0x2d4e3310)), THEROES_SND, THEROES_BG, THEROES_OBJ)),
    "theroesa":  _set("theroes", 6, _gaia((("u0127", 0xa2c599a7), ("u0129", 0xf205a715)), THEROES_SND, THEROES_BG, THEROES_OBJ)),
}


# --------------------------------------------------------------- ROM finding
def zip_stem(name):
    """ddonpach(1).zip and ddonpach (1).zip are ddonpach.zip downloaded again."""
    return re.sub(r"\s*\(\d+\)$", "", os.path.splitext(name)[0]).lower()


class RomIndex:
    """Every ROM file under ZIPDIR, keyed by (size, crc32).

    Zips: the central directory gives both without decompressing anything.
    Loose files: only under ZIPDIR/<set>/ for the sets asked about (and their
    parents), hashed on demand — a whole Downloads folder is not read.
    """

    def __init__(self, zipdir):
        self.zipdir = zipdir
        self.entries = {}        # (size, crc) -> [(stem, kind, path, member)]
        self._loose_done = set()
        for name in sorted(os.listdir(zipdir)):
            path = os.path.join(zipdir, name)
            if name.lower().endswith(".zip") and os.path.isfile(path):
                try:
                    zf = zipfile.ZipFile(path)
                except (zipfile.BadZipFile, OSError):
                    continue
                stem = zip_stem(name)
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    self.entries.setdefault((info.file_size, info.CRC), []).append(
                        (stem, "zip", path, info.filename))
                zf.close()

    def _add_loose(self, setname):
        if setname in self._loose_done:
            return
        self._loose_done.add(setname)
        d = os.path.join(self.zipdir, setname)
        if not os.path.isdir(d):
            return
        for root, _, files in os.walk(d):
            for f in files:
                p = os.path.join(root, f)
                with open(p, "rb") as fh:
                    data = fh.read()
                self.entries.setdefault((len(data), zlib.crc32(data)), []).append(
                    (setname, "file", p, None))

    def find(self, size, crc, prefer):
        for s in prefer:
            self._add_loose(s)
        cands = self.entries.get((size, crc), [])
        if not cands:
            return None
        rank = {s: i for i, s in enumerate(prefer)}
        return sorted(cands, key=lambda c: (rank.get(c[0], len(prefer)), c[0]))[0]

    def read(self, size, crc, prefer, name):
        hit = self.find(size, crc, prefer)
        if hit is None:
            raise SystemExit(f"missing ROM {name} (size {size:#x}, crc {crc:08x}) "
                             f"in {self.zipdir}: looked in every zip, preferring "
                             f"{', '.join(p + '.zip' for p in prefer)}")
        _, kind, path, member = hit
        if kind == "zip":
            with zipfile.ZipFile(path) as zf:
                data = zf.read(member)      # zipfile checks the CRC as it reads
        else:
            with open(path, "rb") as fh:
                data = fh.read()
        if len(data) != size or zlib.crc32(data) != crc:
            raise SystemExit(f"{name}: {path}:{member} does not match its CRC")
        return data, f"{os.path.basename(path)}:{member}" if member else path


# ------------------------------------------------------------- region build
def build_regions(setname, index, log=print):
    """The set's regions in the image's byte order, by name."""
    spec = SETS[setname]
    prefer = [setname] + ([spec["parent"]] if spec["parent"] else [])
    out = {}
    for rname in LAYOUT_ORDER:
        if rname not in spec["regions"]:
            continue
        size, ops = spec["regions"][rname]
        buf = bytearray(size)
        for op in ops:
            kind = op[0]
            if kind == "I":
                _, (na, ca), (nb, cb), off, length = op
                a, wa = index.read(length, ca, prefer, na)
                b, wb = index.read(length, cb, prefer, nb)
                end = off + 2 * length
                if end > size:
                    raise SystemExit(f"{setname}:{rname}: {na}/{nb} overrun the region")
                buf[off:end:2] = a
                buf[off + 1:end:2] = b
                log(f"    {rname:<8} {off:#09x} I {na:<20} {ca:08x} <- {wa}")
                log(f"    {rname:<8} {off + 1:#09x} I {nb:<20} {cb:08x} <- {wb}")
                continue
            _, name, crc, off, length = op
            data, where = index.read(length, crc, prefer, name)
            if kind == "L":
                end = off + length
                if end > size:
                    raise SystemExit(f"{setname}:{rname}: {name} overruns the region")
                buf[off:end] = data
            elif kind == "B":
                end = off + 2 * length - 1
                if end > size:
                    raise SystemExit(f"{setname}:{rname}: {name} overruns the region")
                buf[off:end:2] = data
            else:
                raise AssertionError(kind)
            log(f"    {rname:<8} {off:#09x} {kind} {name:<20} {crc:08x} <- {where}")
        out[rname] = bytes(buf)
    return out


def layout(setname):
    """[(region, offset, size)] for the set, packed in LAYOUT_ORDER."""
    spec = SETS[setname]
    pos, table = 0, []
    for rname in LAYOUT_ORDER:
        if rname in spec["regions"]:
            size = spec["regions"][rname][0]
            table.append((rname, pos, size))
            pos += size
    expect = OFFSETS[spec["game"]]
    for rname, off, _ in table:
        if rname in expect and expect[rname] != off:
            raise SystemExit(f"{setname}: {rname} packs to {off:#x}, the board expects {expect[rname]:#x}")
    return table


def build_image(setname, regions):
    table = layout(setname)
    img = bytearray(table[-1][1] + table[-1][2])
    for rname, off, size in table:
        data = regions[rname]
        if len(data) != size:
            raise SystemExit(f"{rname} is {len(data):#x}, not {size:#x}")
        img[off:off + size] = data
    return bytes(img)


# -------------------------------------------------------------------- main
def expand_sets(arg):
    if arg == "all":
        return list(SETS)
    names = arg.split(",")
    for n in names:
        if n not in SETS:
            raise SystemExit(f"unknown set {n!r}; known: {', '.join(SETS)}")
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("zipdir", help="directory holding the MAME zips")
    ap.add_argument("outdir", help="output directory (keep it under build/)")
    ap.add_argument("--regions", action="store_true",
                    help="write <set>_<region>.bin per region instead of <set>.rom")
    ap.add_argument("--layout", action="store_true", help="print each set's layout and stop")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    if a.layout:
        for s in expand_sets(a.set):
            print(f"{s}: game id {SETS[s]['game']}")
            for rname, off, size in layout(s):
                print(f"    {rname:<8} {off:#09x} {size:#09x}")
        return 0

    index = RomIndex(os.path.expanduser(a.zipdir))
    os.makedirs(a.outdir, exist_ok=True)
    log = (lambda *x: None) if a.quiet else print
    for s in expand_sets(a.set):
        print(f"{s}: game id {SETS[s]['game']}")
        regions = build_regions(s, index, log)
        if a.regions:
            for rname in LAYOUT_ORDER:
                if rname not in regions:
                    continue
                p = os.path.join(a.outdir, f"{s}_{rname}.bin")
                with open(p, "wb") as f:
                    f.write(regions[rname])
                print(f"  {p}  {len(regions[rname]):#x}")
        else:
            img = build_image(s, regions)
            p = os.path.join(a.outdir, f"{s}.rom")
            with open(p, "wb") as f:
                f.write(img)
            print(f"  {p}  {len(img)} bytes  sha1 {hashlib.sha1(img).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
