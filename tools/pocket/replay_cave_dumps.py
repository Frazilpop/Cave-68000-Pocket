#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render MAME's dumped frames on the board, and compare them pixel for pixel.

    python3 tools/pocket/replay_cave_dumps.py SET DUMPDIR [frames] [--out DIR] [--png]
                                              [--mame-budget] [-j N]

For each f<NNNNN> under DUMPDIR (tools/mame_cave_dump.lua's) that recorded a
sprite draw – or the frames listed, comma-separated – this builds the loader
(cave_dump_loader.py), runs the harness on build/pocket/SET.rom with it
(build/obj_ddonpach/tb_ddonpach --prog --replay; sim/ddonpach/build.sh first)
and holds what the board shows against MAME:

  picture   frame_N.ppm against screen.png (RGB, 320 x the screen's height)
  sprites   the sprite layer on screen, sprites_N.bin, against
            sprite_bitmap.bin: pixels where either is opaque and they differ,
            and of those how many only one of the two draws

--mame-budget cuts each list where MAME's sprite budget ran out
(cave_dump_loader.py --mame-budget), so the frames MAME cut compare too.
The harness runs -j at a time (default: the cores). With --png, the pictures that differ get diff_NNNNN.png (sim | MAME |
difference) beside them, through diff_cave_frame.py. Run from the repository
root. Reads derived files and the image only through the harness.
"""

import glob
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PIL import Image

GAME = {"dfeveron": 0, "feversos": 0, "ddonpach": 1, "ddonpachj": 1,
        "esprade": 3, "espradej": 3, "espradejo": 3, "uopoko": 4, "uopokoj": 4,
        "guwange": 5, "guwanges": 5, "gaia": 6, "theroes": 6, "theroesa": 6}
HERE = os.path.dirname(os.path.abspath(__file__))
TB = "build/obj_ddonpach/tb_ddonpach"


def main():
    args, out, png, budget, jobs = [], None, False, [], os.cpu_count()
    it = iter(sys.argv[1:])
    for a in it:
        if a == "--out":
            out = next(it)
        elif a == "--png":
            png = True
        elif a == "--mame-budget":
            budget = [a]
        elif a == "-j":
            jobs = int(next(it))
        else:
            args.append(a)
    if len(args) < 2:
        sys.exit(__doc__)
    setname, dumpdir = args[0], args[1]
    out = out or os.path.join("build/sim/replay", setname)
    os.makedirs(out, exist_ok=True)
    if len(args) > 2:
        frames = [int(f) for f in args[2].split(",")]
    else:
        frames = sorted(int(re.search(r"f(\d+)$", d).group(1))
                        for d in glob.glob(os.path.join(dumpdir, "f*"))
                        if os.path.exists(os.path.join(d, "spriteram_at_draw.bin")))

    def render(n):
        d = os.path.join(dumpdir, f"f{n:05d}")
        prog = os.path.join(out, f"f{n:05d}.prog")
        subprocess.run([sys.executable, "-I", os.path.join(HERE, "cave_dump_loader.py"), d, prog] + budget,
                       check=True, stdout=subprocess.DEVNULL)
        return subprocess.run([TB, f"build/pocket/{setname}.rom", str(GAME[setname]), "60", out,
                               "--prog", prog, "--replay", str(n)], capture_output=True, text=True)

    with ThreadPoolExecutor(jobs) as pool:
        runs = dict(zip(frames, pool.map(render, frames)))

    print(f"{'frame':>6} {'picture px':>11} {'sprite px':>10} {'only MAME':>10} {'only board':>11} {'MAME opaque':>12}")
    bad = 0
    for n in frames:
        d = os.path.join(dumpdir, f"f{n:05d}")
        info = json.load(open(os.path.join(d, "frame.json")))
        h = info["height"]
        r = runs[n]
        if r.returncode:
            print(f"{n:>6}  harness failed: {r.stderr.strip().splitlines()[-1:]}")
            bad += 1
            continue
        sim = np.asarray(Image.open(os.path.join(out, f"frame_{n:05d}.ppm")).convert("RGB"), dtype=np.int16)[:h]
        ref = np.asarray(Image.open(os.path.join(d, "screen.png")).convert("RGB"), dtype=np.int16)[:h]
        pic = int(np.any(sim != ref, axis=2).sum())
        s_sim = np.fromfile(os.path.join(out, f"sprites_{n:05d}.bin"), dtype="<u2").reshape(240, 320)[:h]
        s_ref = np.fromfile(os.path.join(d, "sprite_bitmap.bin"), dtype="<u2").reshape(-1, 320)[:h]
        # transparent is pen 0, whatever the colour and priority bits say
        o_sim, o_ref = (s_sim & 0xff) != 0, (s_ref & 0xff) != 0
        diff = (o_sim | o_ref) & ((s_sim != s_ref) | (o_sim != o_ref))
        print(f"{n:>6} {pic:>11} {int(diff.sum()):>10} {int((o_ref & ~o_sim).sum()):>10} "
              f"{int((o_sim & ~o_ref).sum()):>11} {int(o_ref.sum()):>12}")
        if pic or diff.any():
            bad += 1
            if png:
                subprocess.run([sys.executable, os.path.join(HERE, "diff_cave_frame.py"), out, dumpdir,
                                str(n), "--out", out], check=False, stdout=subprocess.DEVNULL)
    print(f"{len(frames) - bad} of {len(frames)} exact")


if __name__ == "__main__":
    main()
