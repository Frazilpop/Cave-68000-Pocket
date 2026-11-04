# Third-party code and licences

This core is **GPL-3.0-only** as a whole, because fx68k is (see below). This
file lists each dependency and what its licence asks for.

## Fetched by `tools/bootstrap.sh`

These land in `third_party/`, pinned in `deps.lock`, and are never committed.

| Component | Licence | Used for |
|---|---|---|
| [jtfpga/fx68k](https://github.com/jtfpga/fx68k) | GPL-3.0-only | The 68000 main CPU |
| [agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) | MIT | Pocket shell IP: data loader, I2S audio, sync FIFO |
| [mamedev/mame](https://github.com/mamedev/mame) (a sparse checkout) | BSD-3-Clause (the Cave files, ymfm) | The reference |
| [jotego/jt51](https://github.com/jotego/jt51) | GPL-3.0-or-later | Only `sim/ym2151`'s `tb_jt51`, which holds it against ymfm; nothing that ships uses it |

### fx68k – GPL-3.0-only
`deps.lock` pins `jtfpga/fx68k`, which is ijor's code repackaged for jtframe –
`hdl/fx68k.sv` is identical apart from line endings. Synthesis takes `hdl/`,
simulation takes its `hdl/verilator/` variant. The bootstrap symlinks
`microrom.mem` and `nanorom.mem` into the repo root, where fx68k loads them
from.

### analogue-pocket-utils – MIT
© 2022 Adam Gastineau. `data_loader.sv`, `sound_i2s.sv` and `sync_fifo.sv`
are used as they are. Keep the notice.

### MAME – BSD-3-Clause (these files only)
The Cave driver in `src/mame/atlus/` – `cave.cpp` (the boards, clocks,
memory maps, inputs and ROM sets), `cave_v.cpp` and `sprite013` – is
BSD-3-Clause, © Luca Elia, and so are `src/devices/video/tmap038` (© Luca
Elia, Paul Priest, David Haywood) and `src/devices/sound/ymz280b.cpp` (©
Aaron Giles). For Air Gallet and Sailor Moon's sound board, the
`cave_z80_state` parts of `cave.cpp`, `src/devices/sound/okim6295.cpp` and
`okiadpcm.cpp`, `src/devices/sound/ymopm.*` and `3rdparty/ymfm` (Aaron
Giles), which `sim/ym2151` compiles in as its reference, are BSD-3-Clause
too. They are the only public documentation of these chips, and nothing
from them is copied into the HDL except ymfm's tables (below). `tools/pocket/build_rom.py` lists
each set's chips, CRCs and sizes as `cave.cpp`'s `ROM_START` blocks give
them.

MAME as a whole is GPL-2.0, and `src/devices/` and `src/emu/` are a mix, so
check each file's header before transcribing anything else.

## In the tree

### MiSTer-devel/Arcade-Cave_MiSTer – GPL-3.0-or-later
The MiSTer core this is built on, by Josh Bassett (nullobject), imported at
`ee191ea`: everything in `rtl/cave/` – the 68000 side, the GPU (the three
layer processors, the sprite processor, blitter and decoder, the mixer),
the YMZ280B, the video timing, the EEPROM, the game tables and the small
memories, queues and clock crossings – trimmed to this board and changed
where the core is checked against MAME. Upstream's headers are kept as
upstream wrote them.

### Arcadia – MIT
`rtl/arcadia/` (`dual_clock_fifo`, `single_port_ram`, `true_dual_port_ram`)
is Josh Bassett's Arcadia library, which upstream carries. © 2020 Josh
Bassett. Keep the notice.

### alphanu1's SDRAM controller – GPL-3.0-or-later
`rtl/mem/kaneko_sdram.sv` and its model, `sim/models/sdram_model.sv`, come
from alphanu1's Kaneko16 MiSTer core, by way of Great 1000 Miles Rally for
the Pocket. The controller follows meathax's System 32 controller (GPL-3.0)
– keep that note in the file. `tools/bootstrap.sh`, `tools/pocket/build_rom.py`,
`verify_rom.py` and `diff_cave_trace.py` grew from that core's tools and
carry its notice too.

### TV80 – MIT
`rtl/tv80/` is Guy Hutchison's TV80 (© 2004 Guy Hutchison), based on Daniel
Wallner's T80, from hutch31/tv80 at `66a131c`: the Z80 of Air Gallet and
Sailor Moon's sound board. It is kept in the tree with two changes, each
described in `tv80_core.v`: MAME's power-on registers, and the NMI answered
in 11 T-states, as a Z80 does. Keep the notice.

### Ports of MAME's sound chips – BSD-3-Clause
The YM2151 of Air Gallet and Sailor Moon's sound board, `rtl/cave/YM2151.sv`,
is written for this core to ymfm's model of the chip, and its sine, power,
phase step, envelope and detune tables are ymfm's (© 2021 Aaron Giles,
BSD-3-Clause). The notice is in the file's header, and goes with the core in
binary form as well.

The references the sound is checked against keep MAME's licence:

- `sim/ymz280b/ymz280b_mame.h` is a port of MAME's `ymz280b.cpp` (Aaron
  Giles), cut to what this board uses.
- `tools/pocket/oki_model.py` is a port of MAME's `okim6295.cpp`,
  `okiadpcm.cpp` and `nmk112.cpp` (Mirko Buffoni, Aaron Giles, Andrew
  Gardner, Alex W. Jackson), cut to what DonPachi uses; its `--z80` mode
  plays Air Gallet and Sailor Moon's two OKIs the same way.

### RndMnkIII's Analogizer module – MIT, with GPL parts
`pocket/src/fpga/analogizer/` is the adapter module of RndMnkIII's
[Analogizer](https://github.com/RndMnkIII/Analogizer) (`analogizer/` at
`4b35f83`, © 2024 RndMnkIII, MIT), only the files it uses, as
`analogizer.qip` lists them. Three of them carry their own licences:
`yc_out.sv` (Mike Simone, GPL-2.0-or-later), `scandoubler.v` (Till Harbaum,
from MiST, GPL-3.0-or-later) and `vga_out_sw.v` (MiSTer's `vga_out`, by
Sorgelig, GPL). Two changes are made, marked in the files: the
scandoubler's pixel clock divider set for this board, and the PlayStation
pad reader left out – its `dualshock_controller.v` is free for
non-commercial use only, which the GPL does not allow.

### Analogue openFPGA core template – Analogue's APF Software License Agreement
`pocket/src/fpga/apf/`, `core_bridge_cmd.v` and the Quartus project files are
Analogue's, under the licence in their headers (with Analogue's Pocket EULA),
which yields to the MIT or GNU licence wherever the two disagree. The
Quartus megafunction output beside them (`pin_ddio_clk`, `mf_datatable`,
`mf_ddio_bidir_12`) is Intel's generated code, and
`build_id_gen.tcl` is Altera's reference design (Altera Reference Design
License), trimmed by Analogue.

## Written for this core

Everything else under `rtl/`, `sim/`, `tools/` and `pocket/` – the board's
top level and its Pocket memory adapters, DonPachi's sound
(`rtl/cave/SoundOki.sv`), Air Gallet and Sailor Moon's sound board
(`rtl/cave/SoundZ80.sv`, with the YM2151 above), the Pocket shell and its
Analogizer wrapper (`pocket_analogizer.sv`), the simulation harnesses and
the tools – is GPL-3.0-or-later, as each file's header says (the combination is
GPL-3.0-only).

`pocket/art/cave68000-banner.png`, the platform image, is made from the
games' logos and artwork, © Cave.

## ROMs

No ROM images, or anything taken from them, are ever committed or distributed.
They're loaded at runtime, and tools that read them write only to `build/`.
