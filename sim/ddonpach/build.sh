#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the whole-board harness. Run from the repository root.
#   sim/ddonpach/build.sh [extra verilator args]
# The binary is build/obj_ddonpach/tb_ddonpach; fx68k reads its microcode
# from microrom.mem and nanorom.mem in the working directory (the bootstrap
# links them at the root), so run it from the root too.
set -euo pipefail
mkdir -p build/obj_ddonpach build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  --top-module cave68000_sim --Mdir "${OBJ:-build/obj_ddonpach}" -o tb_ddonpach \
  -CFLAGS -O2 "$@" \
  rtl/cave/savestate/*.sv \
  rtl/cave/*.sv rtl/top/cave68000.sv \
  sim/models/arcadia_models.sv \
  third_party/fx68k/hdl/verilator/*.sv \
  sim/ddonpach/cave68000_sim.sv sim/ddonpach/tb_ddonpach.cpp
