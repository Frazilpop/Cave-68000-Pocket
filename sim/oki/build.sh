#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build DonPachi's sound bench. Run from the repository root.
#   sim/oki/build.sh            (OBJ= another directory, default build/obj_oki)
# $OBJ/tb_oki    the board's two OKIs and NMK112 (rtl/cave/SoundOki.sv) from a
#                log, against tools/pocket/oki_model.py's port of MAME's
set -euo pipefail
# a Quartus compile already running is waited for (tools/wait_quartus.sh)
tools/wait_quartus.sh
OBJ=${OBJ:-build/obj_oki}
mkdir -p "$OBJ" build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style \
  --top-module SoundOki --Mdir "$OBJ" -o tb_oki \
  -CFLAGS "-O2 -std=c++17" \
  rtl/cave/SoundOki.sv sim/oki/tb_oki.cpp
