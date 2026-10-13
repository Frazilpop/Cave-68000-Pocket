#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the YMZ280B's testbenches. Run from the repository root.
#   sim/ymz280b/build.sh            (OBJ= another directory, default build/obj_ymz)
# $OBJ/tb_ymz280b    the board's chip against MAME's, from a log
# $OBJ/model_vs_mame MAME's chip, ported, against MAME's own WAV
set -euo pipefail
OBJ=${OBJ:-build/obj_ymz}
mkdir -p "$OBJ" build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style \
  --top-module tb_ymz280b_top --Mdir "$OBJ" -o tb_ymz280b \
  -CFLAGS "-O2 -std=c++17 -I$PWD/sim/ymz280b" \
  rtl/cave/Sound.sv rtl/cave/YMZ280B.sv rtl/cave/ChannelController.sv \
  sim/ymz280b/tb_ymz280b_top.sv sim/ymz280b/tb_ymz280b.cpp
c++ -O2 -std=c++17 -o "$OBJ/model_vs_mame" sim/ymz280b/model_vs_mame.cpp
