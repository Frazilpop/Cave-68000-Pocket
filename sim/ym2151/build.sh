#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the YM2151 bench: jt51 (third_party/jt51) against MAME's ymfm
# (third_party/mame/3rdparty/ymfm). Run from the repository root.
#   sim/ym2151/build.sh            (OBJ= another directory, default build/obj_ym2151;
#                                   JT51= another copy of jt51's hdl/)
set -euo pipefail
# a Quartus compile already running is waited for (tools/wait_quartus.sh)
tools/wait_quartus.sh
OBJ=${OBJ:-build/obj_ym2151}
# JT51= another copy of jt51's hdl/ to try a change on
JT51=${JT51:-third_party/jt51/hdl}
YMFM=$PWD/third_party/mame/3rdparty/ymfm/src
mkdir -p "$OBJ" build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style --public-flat-rw \
  --top-module jt51 --Mdir "$OBJ" -o tb_jt51 \
  -I"$JT51" \
  -CFLAGS "-O2 -std=c++17 -I$YMFM" \
  $(grep '^jt51.*\.v$' "$JT51/jt51.f" | sed "s|^|$JT51/|") sim/ym2151/tb_jt51.cpp \
  "$YMFM/ymfm_opm.cpp" "$YMFM/ymfm_misc.cpp" "$YMFM/ymfm_adpcm.cpp" "$YMFM/ymfm_ssg.cpp"
