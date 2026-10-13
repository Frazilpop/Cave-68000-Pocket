#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the whole-board harness. Run from the repository root.
#   sim/ddonpach/build.sh [extra verilator args]
#   sim/ddonpach/build.sh --pocket [extra verilator args]
# The binary is build/obj_ddonpach/tb_ddonpach: the board with behavioural
# memories in upstream's protocols. With --pocket it is build/obj_pocket/
# tb_pocket: the board behind its Pocket adapters (rtl/top/cave68000_mem.sv)
# on the shell's own memory servants and models of the parts
# (sim/ddonpach/cave68000_psim.sv). fx68k reads its microcode from
# microrom.mem and nanorom.mem in the working directory (the bootstrap links
# them at the root), so run either from the root too.
set -euo pipefail
pocket=0
if [ "${1:-}" = "--pocket" ]; then pocket=1; shift; fi
mkdir -p build/tmp
export TMPDIR="$PWD/build/tmp"
common=(--cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD
  rtl/cave/savestate/*.sv rtl/cave/*.sv rtl/top/cave68000.sv
  sim/models/arcadia_models.sv third_party/fx68k/hdl/verilator/*.sv)
if [ "$pocket" = 1 ]; then
  obj=${OBJ:-build/obj_pocket}
  mkdir -p "$obj"
  verilator "${common[@]}" \
    --top-module cave68000_psim --Mdir "$obj" -o tb_pocket \
    -CFLAGS "-O2 -DPOCKET_MEM" "$@" \
    rtl/mem/*.sv rtl/top/cave68000_mem.sv \
    pocket/src/fpga/core/pocket_psram_rows.sv \
    sim/models/sdram_model.sv sim/models/psram_model.sv \
    sim/ddonpach/cave68000_psim.sv sim/ddonpach/tb_ddonpach.cpp
else
  obj=${OBJ:-build/obj_ddonpach}
  mkdir -p "$obj"
  verilator "${common[@]}" \
    --top-module cave68000_sim --Mdir "$obj" -o tb_ddonpach \
    -CFLAGS -O2 "$@" \
    sim/ddonpach/cave68000_sim.sv sim/ddonpach/tb_ddonpach.cpp
fi
