#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the whole-board harness. Run from the repository root.
#   sim/ddonpach/build.sh [extra verilator args]
#   sim/ddonpach/build.sh --pocket [extra verilator args]
#   sim/ddonpach/build.sh [--pocket] --oki [extra verilator args]
#   sim/ddonpach/build.sh [--pocket] --z80 [extra verilator args]
# The binary is build/obj_ddonpach/tb_ddonpach: the board with behavioural
# memories in upstream's protocols. --oki builds the board as the DonPachi
# bitstream has it (CAVE_OKI: SoundOki in place of the YMZ280B), into
# build/obj_donpachi/tb_ddonpach (with --pocket build/obj_pocket_oki/).
# --z80 builds it as the Air Gallet and Sailor Moon bitstream has it
# (CAVE_Z80: game ids 9 and 10, the Z80 sound board in place of the
# YMZ280B), into build/obj_z80/ (with --pocket build/obj_pocket_z80/).
# --anz (last, with none of the others) builds the reference with the shell's
# pocket_analogizer and RndMnkIII's module (pocket/src/fpga/analogizer/) on
# the board's raster, into build/obj_anz/: tb_ddonpach's --anz-* options.
# With --pocket it is build/obj_pocket/
# tb_pocket: the board behind its Pocket adapters (rtl/top/cave68000_mem.sv)
# on the shell's own memory servants and models of the parts
# (sim/ddonpach/cave68000_psim.sv). fx68k reads its microcode from
# microrom.mem and nanorom.mem in the working directory (the bootstrap links
# them at the root), so run either from the root too.
set -euo pipefail
# a Quartus compile already running is waited for (tools/wait_quartus.sh)
tools/wait_quartus.sh
pocket=0 oki=0 z80=0
if [ "${1:-}" = "--pocket" ]; then pocket=1; shift; fi
if [ "${1:-}" = "--oki" ]; then oki=1; shift; fi
if [ "${1:-}" = "--z80" ]; then z80=1; shift; fi
anz=0
if [ "${1:-}" = "--anz" ]; then anz=1; shift; fi
mkdir -p build/tmp
export TMPDIR="$PWD/build/tmp"
tv80=rtl/tv80
common=(--cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD
  rtl/cave/savestate/*.sv rtl/cave/*.sv rtl/top/cave68000.sv
  sim/models/arcadia_models.sv third_party/fx68k/hdl/verilator/*.sv
  $tv80/tv80_core.v $tv80/tv80_alu.v $tv80/tv80_mcode.v $tv80/tv80_reg.v)
if [ "$oki" = 1 ]; then common+=(+define+CAVE_OKI -CFLAGS -DCAVE_OKI); fi
if [ "$z80" = 1 ]; then common+=(+define+CAVE_Z80 -CFLAGS -DCAVE_Z80); fi
if [ "$anz" = 1 ]; then
  # scandoubler.v's colour-depth branch for a remainder it never has here
  # selects zero bits, which Quartus passes over and Verilator refuses: the
  # harness compiles a copy with the width held at one
  sed 's/ -:n\]/ -:(n>0?n:1)]/g' pocket/src/fpga/analogizer/scandoubler.v > build/tmp/scandoubler_sim.v
  # serlatch_gc.v reads a seventeenth bit from NES and SNES pads into bit 16
  # of a 16-bit register: a write that does nothing (IEEE 1800 11.5.1, and
  # Quartus), which Verilator wraps onto bit 0, the pads' first button
  sed 's/^\( *\)\(p[12]b_r\[((counter>>1)-1)\] <= i_dat[12];\)/\1if (((counter>>1)-1) < 6'"'"'d16) \2/' \
    pocket/src/fpga/analogizer/serlatch_gc.v > build/tmp/serlatch_gc_sim.v
  common+=(+define+ANALOGIZER -CFLAGS -DANALOGIZER
    pocket/src/fpga/core/pocket_sync.sv pocket/src/fpga/core/pocket_analogizer.sv
    $(ls pocket/src/fpga/analogizer/*.v pocket/src/fpga/analogizer/*.sv | grep -v -e scandoubler.v -e serlatch_gc.v)
    build/tmp/scandoubler_sim.v build/tmp/serlatch_gc_sim.v)
fi
if [ "$pocket" = 1 ]; then
  obj=${OBJ:-build/obj_pocket}
  [ "$oki" = 1 ] && obj=${OBJ:-build/obj_pocket_oki}
  [ "$z80" = 1 ] && obj=${OBJ:-build/obj_pocket_z80}
  mkdir -p "$obj"
  verilator "${common[@]}" \
    --top-module cave68000_psim --Mdir "$obj" -o tb_pocket \
    -CFLAGS "-O2 -DPOCKET_MEM" "$@" \
    rtl/mem/*.sv rtl/top/cave68000_mem.sv \
    pocket/src/fpga/core/pocket_psram_rows.sv pocket/src/fpga/core/pocket_sram.sv \
    sim/models/sdram_model.sv sim/models/psram_model.sv sim/models/sram_model.sv \
    sim/ddonpach/cave68000_psim.sv sim/ddonpach/tb_ddonpach.cpp
else
  obj=${OBJ:-build/obj_ddonpach}
  [ "$anz" = 1 ] && obj=${OBJ:-build/obj_anz}
  [ "$oki" = 1 ] && obj=${OBJ:-build/obj_donpachi}
  [ "$z80" = 1 ] && obj=${OBJ:-build/obj_z80}
  mkdir -p "$obj"
  verilator "${common[@]}" \
    --top-module cave68000_sim --Mdir "$obj" -o tb_ddonpach \
    -CFLAGS -O2 "$@" \
    sim/ddonpach/cave68000_sim.sv sim/ddonpach/tb_ddonpach.cpp
fi
