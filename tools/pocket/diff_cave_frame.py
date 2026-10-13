#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the harness's frames with MAME's pictures, pixel for pixel.

    python3 tools/pocket/diff_cave_frame.py SIMDIR MAMEDUMP [frames] [--shift K] [--out DIR]
    python3 tools/pocket/diff_cave_frame.py --match SIMDIR MAMEDIR... [frames]
    python3 tools/pocket/diff_cave_frame.py --window W SIMDIR MAMEDIR [frames] [--out DIR]

SIMDIR holds sim/ddonpach's frame_NNNNN.ppm; MAMEDUMP is a
tools/mame_cave_dump.lua directory (f<NNNNN>/screen.png). Frame N of the
harness is held against MAME's picture N + K (--shift, default 0: both count
pictures from power-on). For each pair it prints the pixels that differ and
their bounding box, and with --out writes sim | MAME | difference (red on a
dimmed MAME) as diff_NNNNN.png.

--window W holds each harness frame N against MAME's pictures N-W .. N+W in
MAMEDIR (a dump or a screens directory) and reports the closest, with its
offset: the runs part in time after the first interrupt, so a frame that
is exact a frame or two away is right.

--match finds, for each harness frame, the MAME picture it is closest to
among every screen.png under the dump directories and every sNNNNN.png /
NNNNN.png in screen directories (tools/mame_cave_screens.lua's): how far the
two runs have drifted apart in time.

Both pictures are the board's own orientation, 320 x 240 (MAME runs with
-norotate). Reads derived pictures only, never the ROMs.
"""

import glob
import os
import re
import sys

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)


def frames_in(simdir):
    out = {}
    for p in glob.glob(os.path.join(simdir, "frame_*.ppm")):
        out[int(re.search(r"frame_(\d+)", p).group(1))] = p
    return out


def mame_pictures(dirs):
    out = {}
    for d in dirs:
        for p in glob.glob(os.path.join(d, "f*", "screen.png")):
            out[int(re.search(r"f(\d+)", os.path.basename(os.path.dirname(p))).group(1))] = p
        for p in glob.glob(os.path.join(d, "*.png")):
            m = re.fullmatch(r"[a-z]?(\d+)\.png", os.path.basename(p))
            if m:
                out.setdefault(int(m.group(1)), p)
    return out


def diff(sim_path, mame_path, out_path=None):
    a, b = load(sim_path), load(mame_path)
    h = min(a.shape[0], b.shape[0])
    a, b = a[:h], b[:h]
    d = np.any(a != b, axis=2)
    n = int(np.count_nonzero(d))
    msg = f"{n:6d} px differ of {d.size}"
    if n:
        ys, xs = np.nonzero(d)
        y0, x0 = ys[0], xs[0]
        msg += (f", box x {xs.min()}-{xs.max()} y {ys.min()}-{ys.max()},"
                f" first ({x0},{y0}) sim {tuple(a[y0, x0])} mame {tuple(b[y0, x0])}")
    if out_path:
        dim = (b // 3).astype(np.uint8)
        dim[d] = [255, 0, 0]
        w = a.shape[1]
        o = Image.new("RGB", (w * 3, h))
        o.paste(Image.fromarray(a.astype(np.uint8)), (0, 0))
        o.paste(Image.fromarray(b.astype(np.uint8)), (w, 0))
        o.paste(Image.fromarray(dim), (2 * w, 0))
        o.save(out_path)
    return n, msg


def main(argv):
    shift, out, match, window = 0, None, False, None
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--shift":
            shift = int(argv[i + 1]); i += 2
        elif argv[i] == "--out":
            out = argv[i + 1]; i += 2
        elif argv[i] == "--window":
            window = int(argv[i + 1]); i += 2
        elif argv[i] == "--match":
            match = True; i += 1
        else:
            args.append(argv[i]); i += 1
    if len(args) < 2:
        print(__doc__)
        return 2
    sim = frames_in(args[0])
    if match:
        dirs = [a for a in args[1:] if os.path.isdir(a)]
        want = {int(x) for a in args[1:] if not os.path.isdir(a) for x in a.split(",")}
        pics = mame_pictures(dirs)
        loaded = {k: load(p) for k, p in pics.items()}
        for f in sorted(sim):
            if want and f not in want:
                continue
            s = load(sim[f])
            best = min(loaded, key=lambda k: np.count_nonzero(np.any(loaded[k][:s.shape[0]] != s[:loaded[k].shape[0]], axis=2)))
            n = np.count_nonzero(np.any(loaded[best][:s.shape[0]] != s[:loaded[best].shape[0]], axis=2))
            print(f"sim {f:5d} ~ mame {best:5d} ({best - f:+d}): {n:6d} px differ")
        return 0
    pics = mame_pictures([args[1]])
    if window is not None:
        want = {int(x) for a in args[2:] for x in a.split(",")}
        if out:
            os.makedirs(out, exist_ok=True)
        worst = 0
        for f in sorted(sim):
            if want and f not in want:
                continue
            s = load(sim[f])
            near = [m for m in range(f - window, f + window + 1) if m in pics]
            if not near:
                continue
            scores = {}
            for m in near:
                b = load(pics[m])
                h = min(s.shape[0], b.shape[0])
                scores[m] = int(np.count_nonzero(np.any(s[:h] != b[:h], axis=2)))
            best = min(near, key=lambda m: (scores[m], abs(m - f)))
            n, msg = diff(sim[f], pics[best], os.path.join(out, f"diff_{f:05d}.png") if out else None)
            worst = max(worst, n)
            print(f"sim {f:5d} ~ mame {best:5d} ({best - f:+d}): {msg}")
        return 1 if worst else 0
    want = {int(x) for a in args[2:] for x in a.split(",")}
    if out:
        os.makedirs(out, exist_ok=True)
    worst = 0
    for f in sorted(sim):
        if want and f not in want:
            continue
        m = f + shift
        if m not in pics:
            continue
        n, msg = diff(sim[f], pics[m], os.path.join(out, f"diff_{f:05d}.png") if out else None)
        worst = max(worst, n)
        print(f"sim {f:5d} / mame {m:5d}: {msg}")
    return 1 if worst else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
