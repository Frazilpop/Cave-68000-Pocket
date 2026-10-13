#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hold the shell's 48 kHz sound against a reference resampling of the board's.

    python3 tools/pocket/audio_check.py BOARD.wav SHELL.wav [--16m]

BOARD.wav is a whole-board run's sound at the chip's rate (tb_ddonpach --wav:
88,200 Hz, or 83,333 Hz with --16m for gaia and theroes); SHELL.wav is what
sim/audio's tb_resample made of it at 48 kHz (pocket_audio_resample). The
reference is scipy's polyphase resampler (Kaiser window, long filter) on the
same samples. The two are lined up by cross-correlation, to a fraction of a
sample (the low-pass's delay is 23 input samples, not a whole number of
48 kHz ones), and compared:

  - error below 16 kHz, where both should agree (the shell's filter is flat
    there): the error's power against the signal's, in dB;
  - the shell's power between 20 and 24 kHz against the reference's, which
    shows anything folded down from above 24 kHz;
  - and, for scale, the same error figure for a plain sample-and-hold, which
    is what feeding the I2S the board's held value would have given.
"""
import sys
import numpy as np
from scipy.signal import resample_poly, butter, sosfiltfilt


def read_wav(path):
    b = open(path, "rb").read()
    i = 12
    while i + 8 <= len(b):
        n = int.from_bytes(b[i + 4:i + 8], "little")
        if b[i:i + 4] == b"data":
            return np.frombuffer(b[i + 8:i + 8 + n], dtype="<i2").astype(np.float64)
        i += 8 + n + (n & 1)
    sys.exit(f"{path}: no data chunk")


def band(x, lo, hi, fs=48000):
    sos = butter(8, [lo, hi], btype="bandpass", fs=fs, output="sos") if lo > 0 else \
          butter(8, hi, btype="lowpass", fs=fs, output="sos")
    return sosfiltfilt(sos, x)


def align(a, b, span=64):
    """The delay d (in samples, fractional) with a[i + d] best matching b[i]:
    the cross-correlation's peak over one second, refined by a parabola through
    the three best points, at five places through the sound, and the median of
    the five (a held tone correlates as well a period either way)."""
    loud = np.nonzero(np.abs(b) > 256)[0]
    if not len(loud):
        return 0.0
    n = 48000
    ds = []
    for q in (0.1, 0.3, 0.5, 0.7, 0.9):
        s0 = int(loud[0] + q * (loud[-1] - loud[0] - n))
        y = b[s0:s0 + n]
        lo = max(0, s0 - span)
        x = a[lo:s0 + n + span]
        c = np.correlate(x, y, mode="valid")
        k = int(np.argmax(c))
        frac = 0.0
        if 0 < k < len(c) - 1:
            den = c[k - 1] - 2 * c[k] + c[k + 1]
            frac = 0.5 * (c[k - 1] - c[k + 1]) / den if den else 0.0
        ds.append(k - (s0 - lo) + frac)
    return float(np.median(ds))


def shift(x, d):
    """x delayed by -d samples (x[i + d]), d fractional: a phase ramp."""
    n = len(x)
    f = np.fft.rfftfreq(n)
    return np.fft.irfft(np.fft.rfft(x) * np.exp(2j * np.pi * f * d), n)


def compare(name, out, ref):
    d = align(out, ref)
    m = min(len(out), len(ref))
    x, y = shift(out[:m], d), ref[:m]
    edge = int(abs(d)) + 100              # the wrapped ends of the shift
    x, y = x[edge:m - edge], y[edge:m - edge]
    lx, ly = band(x, 0, 16000), band(y, 0, 16000)
    err = 10 * np.log10(np.sum(ly ** 2) / max(np.sum((lx - ly) ** 2), 1e-9))
    hx, hy = band(x, 20000, 23900), band(y, 20000, 23900)
    hi = 10 * np.log10(max(np.sum(hx ** 2), 1e-9) / max(np.sum(hy ** 2), 1e-9))
    print(f"{name:<14} delay {d:+.2f}; below 16 kHz the error is {err:.1f} dB under the signal; "
          f"20-24 kHz power {hi:+.1f} dB against the reference")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    m16 = "--16m" in sys.argv
    board, shell = read_wav(args[0]), read_wav(args[1])
    up, down = (72, 125) if m16 else (80, 147)
    ref = resample_poly(board, up, down, window=("kaiser", 10.0))
    fs_in = 16e6 / 192 if m16 else 88200.0
    t = np.arange(int(len(board) * 48000 / fs_in)) * fs_in / 48000
    hold = board[np.minimum(t.astype(int), len(board) - 1)]
    compare("shell", shell, ref)
    compare("sample-hold", hold, ref)


if __name__ == "__main__":
    main()
