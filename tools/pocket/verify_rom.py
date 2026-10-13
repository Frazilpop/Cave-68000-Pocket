#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core, Analogue Pocket port — Copyright (C) 2026 alphanu1
# Adapted for Cave 68000: this board's regions and byte orders.
"""Check <set>.rom byte for byte against the regions MAME itself loads.

    python3 -I tools/pocket/verify_rom.py all --zipdir ~/Downloads --romdir build/pocket

For each set: puts the set's files under build/mame/roms/<set>/ by their MAME
names (found by CRC, so a merged zip under any name will do), runs MAME on
that with tools/mame_cave_regions.lua (dumps into build/mame/regions/<set>/,
skipped with --no-mame if they are already there),
then compares every region of the .rom image with MAME's:

  * prog, layer0-2, ymz, eeprom – the slice must equal MAME's region exactly.
  * sprites – the image keeps the files as the MiSTer core reads them
    (build_rom.py), MAME's region is what ROM_LOAD16_WORD_SWAP (ddonpach) or
    ROM_LOAD32_WORD_SWAP (esprade, guwange) made of the same files, so the
    slice is compared through that permutation: ddonpach's bytes swapped in
    pairs; esprade's and guwange's in groups of four, image [a0 b0 a1 b1]
    against MAME's [a1 a0 b1 b0].
  * the image must be exactly the regions' total, nothing over.

Exit status 0 only if every set matches.
"""

import argparse
import os
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_rom  # noqa: E402  (our own module, beside this file)

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LUA = os.path.join(REPO, "tools", "mame_cave_regions.lua")
MAME_NAME = {"prog": "maincpu", "eeprom": "eeprom", "ymz": "ymz", "layer0": "layer0",
             "layer1": "layer1", "layer2": "layer2", "sprites": "sprites0"}


def stage_rompath(setname, index):
    """MAME finds a set's files by the zip's or folder's name, so a merged
    zip a browser called ddonpach(1).zip is invisible to it. The set's files
    are put under build/mame/roms/<set>/ by their MAME names (found by CRC
    through build_rom's index) and MAME is pointed there."""
    roms = os.path.join(REPO, "build", "mame", "roms")
    d = os.path.join(roms, setname)
    os.makedirs(d, exist_ok=True)
    spec = build_rom.SETS[setname]
    prefer = [setname] + ([spec["parent"]] if spec["parent"] else [])
    for _, ops in spec["regions"].values():
        for op in ops:
            files = [(op[1], op[2], op[4])] if op[0] in ("L", "B") else [(op[1][0], op[1][1], op[4]), (op[2][0], op[2][1], op[4])]
            for name, crc, size in files:
                path = os.path.join(d, name)
                if os.path.exists(path) and os.path.getsize(path) == size:
                    continue
                data, _ = index.read(size, crc, prefer, name)
                with open(path, "wb") as f:
                    f.write(data)
    return roms


def run_mame(setname, zipdir, dumpdir, mame, index):
    os.makedirs(dumpdir, exist_ok=True)
    work = os.path.join(REPO, "build", "mame", "work")
    env = dict(os.environ, DUMP_DIR=dumpdir)
    rompath = stage_rompath(setname, index)
    cmd = [mame, "-rompath", rompath, setname,
           "-autoboot_script", LUA, "-skip_gameinfo", "-autoboot_delay", "0",
           "-video", "none", "-sound", "none", "-nothrottle", "-seconds_to_run", "60",
           "-cfg_directory", os.path.join(work, "cfg"),
           "-nvram_directory", os.path.join(work, "nvram"),
           "-snapshot_directory", os.path.join(work, "snap")]
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if not os.path.exists(os.path.join(dumpdir, "regions.txt")):
        sys.stdout.write(r.stdout + r.stderr)
        raise SystemExit(f"{setname}: MAME did not dump its regions")


def to_mame_order(setname, rname, data):
    """The image's slice as MAME's loader would have laid it out."""
    if rname != "sprites":
        return data
    game = build_rom.SETS[setname]["game"]
    out = bytearray(len(data))
    if game == 1:                       # ddonpach: ROM_LOAD16_WORD_SWAP
        out[0::2] = data[1::2]
        out[1::2] = data[0::2]
        return bytes(out)
    if game in (3, 5):                  # esprade, guwange: ROM_LOAD32_WORD_SWAP of a byte-interleaved pair
        out[0::4] = data[2::4]          # mame[4j]   = A[2j+1] = img[4j+2]
        out[1::4] = data[0::4]          # mame[4j+1] = A[2j]   = img[4j]
        out[2::4] = data[3::4]          # mame[4j+2] = B[2j+1] = img[4j+3]
        out[3::4] = data[1::4]          # mame[4j+3] = B[2j]   = img[4j+1]
        return bytes(out)
    return data                         # plain ROM_LOAD


def first_diff(a, b):
    n = min(len(a), len(b))
    if a[:n] == b[:n]:
        return None
    lo, hi = 0, n            # binary search on equal prefixes
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if a[:mid] == b[:mid]:
            lo = mid
        else:
            hi = mid
    return lo if a[lo] != b[lo] else hi - 1


def count_diff(a, b):
    try:
        import numpy as np
        return int(np.count_nonzero(np.frombuffer(a, np.uint8) != np.frombuffer(b, np.uint8)))
    except ImportError:
        return sum(x != y for x, y in zip(a, b))


def verify(setname, romdir, dumpdir):
    img = open(os.path.join(romdir, f"{setname}.rom"), "rb").read()
    table = build_rom.layout(setname)
    total = table[-1][1] + table[-1][2]
    if len(img) != total:
        return False, [f"  image is {len(img):#x} bytes, expected {total:#x}"]
    ok = True
    lines = []
    for rname, base, size in table:
        mame = open(os.path.join(dumpdir, f"{MAME_NAME[rname]}.bin"), "rb").read()
        mine = to_mame_order(setname, rname, img[base:base + size])
        note = " (through the sprite permutation)" if rname == "sprites" and mine != img[base:base + size] else ""
        if len(mame) != size:
            ok = False
            lines.append(f"  {rname:<8} @{base:#09x}  MAME's region is {len(mame):#x} bytes, the image's {size:#x}")
            continue
        d = first_diff(mine, mame)
        if d is None:
            lines.append(f"  {rname:<8} @{base:#09x}  {size:#09x} bytes  MATCH{note}")
        else:
            ok = False
            lines.append(f"  {rname:<8} @{base:#09x}  MISMATCH{note}: {count_diff(mine, mame)} bytes differ, "
                         f"first at +{d:#x} (rom {mine[d]:02x}, mame {mame[d]:02x})")
    return ok, lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("--zipdir", default=os.path.expanduser("~/Downloads"))
    ap.add_argument("--romdir", default=os.path.join(REPO, "build", "pocket"))
    ap.add_argument("--dumpdir", default=os.path.join(REPO, "build", "mame", "regions"))
    ap.add_argument("--mame", default="mame")
    ap.add_argument("--no-mame", action="store_true", help="reuse existing region dumps")
    a = ap.parse_args()

    all_ok = True
    index = None if a.no_mame else build_rom.RomIndex(os.path.expanduser(a.zipdir))
    for s in build_rom.expand_sets(a.set):
        d = os.path.join(a.dumpdir, s)
        if not a.no_mame:
            run_mame(s, os.path.expanduser(a.zipdir), d, a.mame, index)
        ok, lines = verify(s, a.romdir, d)
        print(f"{s}: {'OK' if ok else 'FAIL'}")
        print("\n".join(lines))
        all_ok &= ok
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
