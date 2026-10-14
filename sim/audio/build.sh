#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the resampler's bench. Run from the repository root.
#   sim/audio/build.sh       -> build/obj_audio/tb_resample
set -euo pipefail
# a Quartus compile already running is waited for (tools/wait_quartus.sh)
tools/wait_quartus.sh
OBJ=${OBJ:-build/obj_audio}
mkdir -p "$OBJ" build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 -Wno-fatal -Wno-lint -Wno-style \
  --top-module pocket_audio_resample --Mdir "$OBJ" -o tb_resample -CFLAGS -O2 \
  pocket/src/fpga/core/pocket_audio_resample.sv sim/audio/tb_resample.cpp
