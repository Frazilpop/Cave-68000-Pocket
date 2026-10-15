# Third-party code and licences

This core is **GPL-3.0-only** as a whole, because fx68k is (see below). This
file lists each dependency and what its licence asks of us.

## Fetched by `tools/bootstrap.sh`

These land in `third_party/`, pinned in `deps.lock`, and are never committed.

| Component | Licence | Used for |
|---|---|---|
| [jtfpga/fx68k](https://github.com/jtfpga/fx68k) | GPL-3.0-only | The 68000 main CPU |
| [agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) | MIT | Pocket shell IP: data loader, I2S audio, sync FIFO |
| [mamedev/mame](https://github.com/mamedev/mame) (a sparse checkout) | BSD-3-Clause (the Cave files) | The reference |

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
Aaron Giles). They are the only public documentation of these chips, and
nothing from them is copied into the HDL. `tools/pocket/build_rom.py` lists
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

### Ports of MAME's sound chips – BSD-3-Clause
The references the sound is checked against keep MAME's licence:

- `sim/ymz280b/ymz280b_mame.h` is a port of MAME's `ymz280b.cpp` (Aaron
  Giles), cut to what this board uses.
- `tools/pocket/oki_model.py` is a port of MAME's `okim6295.cpp`,
  `okiadpcm.cpp` and `nmk112.cpp` (Mirko Buffoni, Aaron Giles, Andrew
  Gardner, Alex W. Jackson), cut to what DonPachi uses.

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
(`rtl/cave/SoundOki.sv`), the Pocket shell, the simulation harnesses and the
tools – is GPL-3.0-or-later, as each file's header says (the combination is
GPL-3.0-only).

`pocket/art/cave68000-banner.png`, the platform image, is made from the
games' logos and artwork, © Cave.

## ROMs

No ROM images, or anything taken from them, are ever committed or distributed.
They're loaded at runtime, and tools that read them write only to `build/`.
