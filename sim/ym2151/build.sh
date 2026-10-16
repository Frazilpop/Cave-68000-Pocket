#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the YM2151 benches against MAME's ymfm (third_party/mame/3rdparty/ymfm).
# Run from the repository root.
#   sim/ym2151/build.sh         $OBJ/tb_ym2151: the board's chip, rtl/cave/YM2151.sv
#   sim/ym2151/build.sh jt51    $OBJ/tb_jt51: jt51 (third_party/jt51, or JT51= another
#                               copy of its hdl/), the chip first tried
# OBJ= another directory (default build/obj_ym2151, build/obj_jt51).
set -euo pipefail
# a Quartus compile already running is waited for (tools/wait_quartus.sh)
tools/wait_quartus.sh
YMFM=$PWD/third_party/mame/3rdparty/ymfm/src
YMFM_SRC="$YMFM/ymfm_opm.cpp $YMFM/ymfm_misc.cpp $YMFM/ymfm_adpcm.cpp $YMFM/ymfm_ssg.cpp"
mkdir -p build/tmp
export TMPDIR="$PWD/build/tmp"
if [ "${1:-}" = jt51 ]; then
  OBJ=${OBJ:-build/obj_jt51}
  JT51=${JT51:-third_party/jt51/hdl}
  verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
    -Wno-fatal -Wno-lint -Wno-style --public-flat-rw \
    --top-module jt51 --Mdir "$OBJ" -o tb_jt51 \
    -I"$JT51" \
    -CFLAGS "-O2 -std=c++17 -I$YMFM" \
    $(grep '^jt51.*\.v$' "$JT51/jt51.f" | sed "s|^|$JT51/|") sim/ym2151/tb_jt51.cpp $YMFM_SRC
else
  OBJ=${OBJ:-build/obj_ym2151}
  verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
    -Wno-fatal -Wno-lint -Wno-style --public-flat-rw -GTSCALE=2 \
    --top-module YM2151 --Mdir "$OBJ" -o tb_ym2151 \
    -CFLAGS "-O2 -std=c++17 -I$YMFM" \
    rtl/cave/YM2151.sv sim/ym2151/tb_ym2151.cpp $YMFM_SRC
fi
