#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build Air Gallet's and Sailor Moon's sound board bench. Run from the
# repository root.
#   sim/z80/build.sh            (OBJ= another directory, default build/obj_z80snd)
# $OBJ/tb_z80   the board's sound board (rtl/cave/SoundZ80.sv: TV80, the
#               YM2151, SoundOki's engine) from a sound-board log
#               (tools/mame_cave_z80.lua), its Z80 held to MAME's
set -euo pipefail
# a Quartus compile already running is waited for (tools/wait_quartus.sh)
tools/wait_quartus.sh
OBJ=${OBJ:-build/obj_z80snd}
TV80=${TV80:-rtl/tv80}
mkdir -p "$OBJ" build/tmp
export TMPDIR="$PWD/build/tmp"
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
  --top-module SoundZ80 --Mdir "$OBJ" -o tb_z80 \
  -CFLAGS "-O2 -std=c++17" \
  "$TV80/tv80_core.v" "$TV80/tv80_alu.v" "$TV80/tv80_mcode.v" "$TV80/tv80_reg.v" \
  rtl/cave/YM2151.sv rtl/cave/SoundOki.sv rtl/cave/SoundZ80.sv sim/z80/tb_z80.cpp
