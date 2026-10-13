#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The low-pass in front of the shell's 88.2 -> 48 kHz resampler.

    python3 tools/pocket/audio_fir.py            print the SystemVerilog table
    python3 tools/pocket/audio_fir.py --response print the response at a few frequencies

pocket/src/fpga/core/pocket_audio_resample.sv runs a 47-tap FIR at the
YMZ280B's own rate (88,200 Hz; 83,333 on gaia and theroes) before taking
48 kHz samples off it by linear interpolation. The taps are a Kaiser-windowed
sinc, cut at 21 kHz, quantised to signed 18 bits (1.0 = 2^17) with the sum
kept at exactly 2^17, so silence stays silence and a held level is not
scaled. Rerun this and paste the table if the filter changes.
"""
import sys
import numpy as np
from scipy.signal import firwin, freqz

FS, TAPS, CUT, BETA, ONE = 88200.0, 47, 21000.0, 6.0, 1 << 17


def taps():
    h = firwin(TAPS, CUT, window=("kaiser", BETA), fs=FS)
    q = np.round(h * ONE).astype(np.int64)
    q[TAPS // 2] += ONE - q.sum()          # the sum exactly 1.0
    return q


def main():
    q = taps()
    if "--response" in sys.argv:
        w, r = freqz(q / ONE, worN=8192, fs=FS)
        for f in (1000, 10000, 16000, 18000, 20000, 22000, 24000, 26000, 28000, 32000, 40000):
            i = int(round(f / (FS / 2) * (len(w) - 1)))
            print(f"{f:6d} Hz  {20 * np.log10(abs(r[i]) + 1e-12):7.2f} dB")
        return
    half = q[: TAPS // 2 + 1]
    print(f"  // tools/pocket/audio_fir.py: {TAPS} taps, Kaiser beta {BETA}, cut {CUT:.0f} Hz at {FS:.0f} Hz;")
    print(f"  // symmetric, tap k = tap {TAPS - 1} - k; 1.0 = 2^17")
    print("  function automatic signed [17:0] coef(input [4:0] k);")
    print("    case (k)")
    for k, v in enumerate(half):
        print(f"      5'd{k}: coef = {'-' if v < 0 else ''}18'sd{abs(int(v))};")
    print("      default: coef = 18'sd0;")
    print("    endcase")
    print("  endfunction")


if __name__ == "__main__":
    main()
