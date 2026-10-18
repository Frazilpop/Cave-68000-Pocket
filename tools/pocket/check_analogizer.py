#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hold the Analogizer's output against the board's own picture, mode by mode.

    python3 tools/pocket/check_analogizer.py [SET DUMPDIR FRAME] [--out DIR] [-j N]

Runs build/obj_anz/tb_ddonpach (sim/ddonpach/build.sh --anz: the board with
the shell's pocket_analogizer and RndMnkIII's module on its raster) once per
setting, each with its own analogizer.bin made as AnalogizerConfigurator makes
it (one 32-bit word, little-endian), and reads what the cartridge pins carry,
as the adapter's DAC would take it, off the harness's anz_NNNNN.raw. The
picture is MAME's dump FRAME of SET (default ddonpach f05400) replayed on the
board (cave_dump_loader.py, --replay): a still frame, the same in every run.

  RGBS, RGsB  csync on the sync pin the mode uses (active low, 4 us), the
              other pin high, the blanking pin; the picture where it is set,
              each dot four clocks, against frame_NNNNN.ppm at 6 bits
  YPbPr       Y, Pb, Pr against MAME's vga_out arithmetic on the same frame,
              and its csync, both the same clocks behind RGBS's
  Y/C         the luma against yc_out's sum, the colour burst's frequency
              on every line (3.579545 or 4.43361875 MHz) and where it falls
              in the back porch, csync on the sync pin
  SC 0-75 %   the scandoubler: hsync every 896 clocks (31.25 kHz), each line
              of the picture twice at two clocks a dot, one of the two dimmed
              by the scanline factor; HQ2x (which this module has not got)
              as SC 0 %
  off         no file, and a file with the Analogizer off: the pins as the
              template's tie-offs on every clock (the harness counts them)
  Pocket off  [14] set: the Pocket's screen black, the adapter's picture on
  SNAC        SNES, NES and DB15 pads on the port, every button pressed in
              turn, under each assignment: the players' controls hold the
              button's bit of cont_key (the Pocket's own controls where SNAC
              does not stand in for them)

Prints a line per run and exits non-zero if any check fails. Run from the
repository root.
"""

import os
import struct
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
TB = "build/obj_anz/tb_ddonpach"
GAME = {"ddonpach": 1, "ddonpachj": 1, "esprade": 3, "uopoko": 4, "guwange": 5, "gaia": 6, "feversos": 0}
LINE = 1792                  # clk_vid clocks a line: 448 dots of four
BIT = {"Up": 0, "Down": 1, "Left": 2, "Right": 3, "A": 4, "B": 5, "X": 6, "Y": 7,
       "L": 8, "R": 9, "Select": 14, "Start": 15}
PADS = {  # SNAC type, and each button's bit in cont_key
    "snes": (3, BIT),
    "nes": (2, BIT),
    "db15": (1, {"A": 4, "B": 5, "C": 6, "D": 7, "E": 8, "F": 9, "Up": 0, "Down": 1,
                 "Left": 2, "Right": 3, "Select": 14, "Start": 15}),
}
CONT1, CONT2 = 0x1001, 0x2002  # the Pocket's own controls, to tell them apart


def word(snac=0, on=1, assign=0, video=0, pocket_off=0):
    return snac | on << 5 | assign << 6 | video << 10 | pocket_off << 14


def pins(path):
    raw = np.fromfile(path, np.uint8).reshape(-1, 5).astype(np.int32)
    b3, b2, b1, misc, b0 = raw.T
    return {"r": b3 >> 2, "hs": b3 >> 1 & 1, "vs": b3 & 1, "g": b2 & 63, "blank": b2 >> 6 & 1,
            "b": (b1 & 31) << 1 | b2 >> 7, "misc": misc, "lat": b1 >> 7 & 1, "clk": b1 >> 6 & 1,
            "bank0": b0 & 15, "pin31": b0 >> 7 & 1}


def falls(x):
    return np.where((x[1:] == 0) & (x[:-1] == 1))[0] + 1


def rises(x):
    return np.where((x[1:] == 1) & (x[:-1] == 0))[0] + 1


def grid(p):
    """The picture's dots in an RGBS run: the first clock of each, lines x 320
    (240 lines, 224 on gaia and theroes): one frame's lines, one a line."""
    bf = rises(p["blank"])
    br = falls(p["blank"])
    br = br[br > bf[0]]
    n = min(len(bf), len(br))
    assert (br[:n] - bf[:n] == 1280).all(), "a picture line is not 320 dots"
    gap = np.where(np.diff(bf) != LINE)[0]
    starts = bf[:gap[0] + 1]
    return starts[:, None] + 4 * np.arange(320)[None, :]


def ypbpr(rgb):
    r, g, b = [rgb[..., i].astype(np.int64) for i in range(3)]
    y = r * 77 + g * 150 + b * 29
    pb = 32768 - r * 42 + 0 - g * 85 + b * 128
    pr = 32768 + r * 128 - g * 106 - b * 21
    out = []
    for v in (pr, y, pb):
        v = v & ((1 << 19) - 1)
        out.append(np.where(v >> 18 & 1, 0, np.where(v >> 16 & 1, 255, v >> 8 & 255)))
    return out  # Pr on R, Y on G, Pb on B


def best_delay(p, pos, exp, chans, lo=-4, hi=40):
    best = None
    for d in range(lo, hi):
        bad = sum(int((p[c][pos + d] != e).sum()) for c, e in zip(chans, exp))
        if best is None or bad < best[1]:
            best = (d, bad)
    return best


def check_15k(p, ref, rgb6, mode):
    """RGBS (0), RGsB (1), YPbPr (2), Y/C (3, 4)."""
    msgs, ok = [], True
    pos = ref["pos"]
    csync_ref = ref["p"]["hs"]
    if mode in (0, 1):
        sync, other = ("hs", "vs") if mode == 0 else ("vs", "hs")
        if not (p[other] == 1).all():
            ok = False; msgs.append(f"{other} pin not held high")
        if not (p[sync] == csync_ref).all():
            ok = False; msgs.append("csync differs from RGBS's")
        exp = [rgb6[..., 0], rgb6[..., 1], rgb6[..., 2]]
        bad = sum(int((p[c][pos + k] != e).sum()) for k in range(4) for c, e in zip("rgb", exp))
        dark = int(((p["r"] | p["g"] | p["b"]) * (1 - p["blank"])).astype(bool).sum())
        if bad or dark:
            ok = False
        msgs.append(f"{bad} dot clocks differ, {dark} lit clocks in blanking")
    elif mode == 2:
        exp = [e >> 2 for e in ypbpr(ref["rgb8"])]
        d, bad = best_delay(p, pos, exp, "rgb")
        ds = next(k for k in range(0, 40) if (p["vs"][k:] == csync_ref[:len(csync_ref) - k]).all())
        if bad or d != ds or not (p["hs"] == 1).all():
            ok = False
        msgs.append(f"Y Pb Pr {d} clocks behind, csync {ds}; {bad} dots differ")
    else:
        rgb = ref["rgb8"].astype(np.int64)
        y = (rgb[..., 0] * 306 + rgb[..., 1] * 601 + rgb[..., 2] * 117) >> 10
        d, bad = best_delay(p, pos, [y >> 2], "g")
        ds = next(k for k in range(0, 40) if (p["hs"][k:] == csync_ref[:len(csync_ref) - k]).all())
        if bad or not (p["vs"] == 1).all() or not (p["b"] == 0).all():
            ok = False
        # the burst, on every line with a whole 4 us hsync: its cycles from
        # the first zero crossing to the last, and where it lies after the
        # hsync's end on the pin (the picture starts ref["porch"] after it)
        hs = p["hs"]
        fr, first, last = [], [], []
        for e in rises(hs):
            if e + 260 > len(hs) or (hs[e - 112:e] == 0).sum() != 112:
                continue
            c = p["r"][e:e + 200] - 32
            nz = np.where(c != 0)[0]
            if len(nz) < 20:
                continue
            first.append(nz[0]); last.append(nz[-1])
            sg = np.sign(c[nz])
            x = nz[1:][sg[1:] != sg[:-1]]
            if len(x) > 4:
                fr.append((len(x) - 1) / 2 / ((x[-1] - x[0]) / 28e6))
        f = np.median(fr) / 1e6 if fr else 0
        want = 4.43361875 if mode == 4 else 3.579545
        end = int(np.median(last)) if last else 0
        if not fr or abs(f - want) > 0.05 or end >= ref["porch"]:
            ok = False
        msgs.append(f"luma {d} clocks behind, csync {ds}; {bad} dots differ; burst on {len(fr)} lines, "
                    f"{f:.3f} MHz (want {want}), clocks {int(np.median(first))}-{end} after hsync "
                    f"(the picture at {ref['porch']})")
    return ok, "; ".join(msgs)


def check_sd(p, rgb6, lines):
    """The scandoubler, with scanlines 0-3 (0, 25, 50, 75 %)."""
    coeff = [64, 0x3a, 0x2e, 0x1a][lines]
    hs, vs = p["hs"], p["vs"]
    hr, hf = rises(hs), falls(hs)
    # its syncs keep the board's polarity: high for the pulse
    u, c = np.unique(np.diff(hr), return_counts=True)
    period = int(u[np.argmax(c)])
    width = int(np.median([hf[hf > r][0] - r for r in hr[:-1]]))
    vsyncs = len(rises(vs))
    # the picture's middle line on an output line, two clocks a dot, at its
    # full level
    lines_n = len(rgb6)
    mid = lines_n // 2
    target = rgb6[mid]
    hit = None
    for li, s0 in enumerate(hr[:-1]):
        for o in range(0, 896 - 640):
            idx = s0 + o + 2 * np.arange(320)
            if all((p[ch][idx] == target[:, k]).all() for k, ch in enumerate("rgb")):
                hit = (li, o)
                break
        if hit:
            break
    head = f"hsync every {period} clocks ({width} high), {vsyncs} vsyncs in two frames"
    if not hit:
        return False, head + f"; board line {mid} not found"
    li, o = hit
    # every line twice: the full one, and beside it the same dimmed (or not,
    # at 0 %); which side the dimmed one is on is the scandoubler's
    bads = []
    for side in (1, -1):
        bad = 0
        for y in range(lines_n):
            for k, lvl in ((0, 64), (side, coeff)):
                l = li + 2 * (y - mid) + k
                if not 0 <= l < len(hr):
                    bad += 640
                    continue
                idx = hr[l] + o + 2 * np.arange(320)
                exp = (rgb6[y] * lvl) >> 6
                for ch in range(3):
                    bad += int((p["rgb"[ch]][idx] != exp[:, ch]).sum())
                    bad += int((p["rgb"[ch]][idx + 1] != exp[:, ch]).sum())
        bads.append(bad)
    bad = min(bads)
    return period == 896 and bad == 0, (f"{head}; {bad} dot clocks differ "
                                        f"(scanlines {[0, 25, 50, 75][lines]} %)")


def check_keys(path, pad, assign):
    _, bits = PADS[pad]
    rows = [l.strip().split(",") for l in open(path)][1:]
    bad, seen = 0, 0
    prev = None
    for fr, b1, b2, k1, k2, snac in rows:
        cur = (b1, b2)
        if cur != prev:            # the first frame of a press: the pads may not have been read yet
            prev = cur
            continue
        s1 = 0 if b1 == "-" else 1 << bits[b1]
        s2 = 0 if b2 == "-" else 1 << bits[b2]
        e1, e2 = {0: (s1, CONT2), 1: (CONT1, s1), 2: (s1, s2), 3: (s2, s1), 4: (CONT1, CONT2),
                  5: (s1, s2)}[assign]
        es = int(assign in (0, 2, 3, 5))
        seen += 1
        if int(k1, 16) != e1 or int(k2, 16) != e2 or int(snac) != es:
            bad += 1
    return bad == 0 and seen > 40, f"{seen} frames, {bad} with the controls wrong"


def main():
    args, out, jobs = [], "build/anz", os.cpu_count()
    it = iter(sys.argv[1:])
    for a in it:
        if a == "--out":
            out = next(it)
        elif a == "-j":
            jobs = int(next(it))
        else:
            args.append(a)
    setname, dumpdir, n = (args + ["ddonpach", "build/mame/dump/ddonpach", "5400"][len(args):])[:3]
    n = int(n)
    os.makedirs(out, exist_ok=True)
    prog = os.path.join(out, f"f{n:05d}.prog")
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "cave_dump_loader.py"),
                    os.path.join(dumpdir, f"f{n:05d}"), prog], check=True, stdout=subprocess.DEVNULL)

    runs = {"rgbs": word(video=0), "rgsb": word(video=1), "ypbpr": word(video=2),
            "yc_ntsc": word(video=3), "yc_pal": word(video=4),
            "sc0": word(video=5), "sc25": word(video=6), "sc50": word(video=7), "sc75": word(video=8),
            "hq2x": word(video=9), "pocket_off": word(video=0, pocket_off=1),
            "file_off": word(on=0, video=0, snac=3), "no_file": None}
    for pad in PADS:
        for a in (0, 1, 2, 3, 4, 5):
            runs[f"{pad}_a{a}"] = word(snac=PADS[pad][0], assign=a)

    def run(name):
        d = os.path.join(out, name)
        os.makedirs(d, exist_ok=True)
        cmd = [TB, f"build/pocket/{setname}.rom", str(GAME[setname]), "120", d]
        if runs[name] is not None:
            open(os.path.join(d, "analogizer.bin"), "wb").write(struct.pack("<I", runs[name]))
            cmd += ["--anz-file", os.path.join(d, "analogizer.bin")]
        pad = name.split("_a")[0] if "_a" in name else None
        if pad in PADS:
            cmd += ["--anz-pad", pad, "--anz-cont", f"{CONT1:x},{CONT2:x}"]
        else:
            cmd += ["--prog", prog, "--replay", str(n), "--anz-raw"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        return r

    with ThreadPoolExecutor(jobs) as pool:
        res = dict(zip(runs, pool.map(run, runs)))

    def anz_line(name):
        return next((l for l in res[name].stderr.splitlines() if l.startswith("analogizer:")), "?")

    fails = 0
    rp = pins(os.path.join(out, "rgbs", f"anz_{n:05d}.raw"))
    rgb8 = np.asarray(Image.open(os.path.join(out, "rgbs", f"frame_{n:05d}.ppm")).convert("RGB")).astype(np.int64)
    ref = {"p": rp, "pos": grid(rp), "rgb8": rgb8}
    hr = rises(rp["hs"])
    bf = rises(rp["blank"])
    ref["porch"] = int(bf[5] - hr[hr < bf[5]][-1])
    rgb8 = rgb8[:len(ref["pos"])]
    ref["rgb8"] = rgb8
    rgb6 = rgb8 >> 2
    for name in runs:
        r = res[name]
        line = anz_line(name)
        want = runs[name]
        if r.returncode != 0:
            ok, msg = False, f"harness exit {r.returncode}: {r.stderr.strip().splitlines()[-1:]}"
        elif "word taken" in line and want is not None and f"word taken {want:08x}" not in line:
            ok, msg = False, f"word not taken as written: {line}"
        elif name in ("no_file", "file_off"):
            off_bad = line.split("template's on ")[1].split(" of ")[0]
            ok, msg = off_bad == "0", line.split("analogizer: ")[1]
        elif "_a" in name:
            pad, a = name.split("_a")
            ok, msg = check_keys(os.path.join(out, name, "anz_keys.csv"), pad, int(a))
        else:
            p = pins(os.path.join(out, name, f"anz_{n:05d}.raw"))
            mode = (want >> 10) & 15
            if mode <= 4:
                ok, msg = check_15k(p, ref, rgb6, mode)
            else:
                ok, msg = check_sd(p, rgb6, (mode - 5) if mode <= 8 else 0)
            if name == "pocket_off":
                ok = ok and "Pocket screen off" in line
                msg += "; " + ("Pocket screen off" if "Pocket screen off" in line else "POCKET SCREEN STILL ON")
            elif "Pocket screen on" not in line:
                ok = False; msg += "; Pocket screen off"
        fails += not ok
        print(f"{name:11} {'ok  ' if ok else 'FAIL'} {msg}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
