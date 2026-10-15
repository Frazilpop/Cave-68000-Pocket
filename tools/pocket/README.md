# Pocket tools

These are the scripts that make the game files for the Analogue Pocket, and
check the core against MAME. The ROMs you supply are written into `build/`.
Run anything that opens the zips with `python3 -I` so Python can't pick up
stray files from the folder you're in.

## Making the `.rom` files

```sh
python3 -I tools/pocket/build_rom.py ddonpach ~/Downloads build/pocket     # one game
python3 -I tools/pocket/build_rom.py all      ~/Downloads build/pocket     # all games
python3 -I tools/pocket/verify_rom.py all --zipdir ~/Downloads --romdir build/pocket   # verify against MAME
```

You can also give a list of ROM ids separated by commas, e.g.
`ddonpach,esprade`.

The core supports the following ROM ids: `donpachi`, `donpachij`,
`donpachijs`, `donpachikr`, `donpachihk`, `ddonpach`, `ddonpachj`, `esprade`,
`espradej`, `espradejo`, `feversos`, `dfeveron`, `uopoko`, `uopokoj`,
`guwange`, `guwanges`, `gaia`, `theroes` and `theroesa`.

Each image holds the game's regions packed one after another, in the order
the MiSTer core's MRAs put them – program, EEPROM, samples, layer 0, layer 1,
layer 2, sprites – so each region starts where the board's game tables
expect it, with no gaps. A set without a region (gaia and theroes have no
EEPROM, uopoko has one layer, feversos two) simply skips it. DonPachi's
image holds its two OKI chips' samples in place of the YMZ280B's: the
second chip's 3 MB as MAME has them, then its last 1 MB again, because the
NMK112 banks it in 64 pages of 64 KB and MAME folds pages 48–63 onto
32–47. `--layout` prints each set's layout.

Bytes are in the order the board reads them: the program as MAME's region
(even byte = the high byte of the 68000's word), the EEPROM, samples and
layers as the zip's files are, and the sprites as the MRAs leave them rather
than MAME's word swap. `verify_rom.py` knows these orders.

The script finds each chip by its CRC32 and size, and will look through every
zip in the folder (the game's own zip and its parent's first; a browser's
`ddonpach(1).zip` counts as `ddonpach.zip`), so merged, split and non-merged
sets all work. A `<rom id>/` folder of loose files works too. The list of
chips is copied from `ROM_START` in MAME's `cave.cpp`. Nothing is patched:
the MiSTer core's MRAs patch DoDonPachi's ROM check and the EEPROMs, but
MAME boots the sets as dumped, and so does this core.

`verify_rom.py` puts each set's files under `build/mame/roms/<rom id>/` by
their MAME names, runs MAME with `tools/mame_cave_regions.lua`, which saves
MAME's own copy of each region to `build/mame/regions/<rom id>/`, then
compares them with the image byte for byte. `--no-mame` reuses regions
already saved, and `--stage` only puts the files in place, for the oracle
scripts below.

For simulation, `--regions` writes one file per MAME region instead:

```sh
python3 -I tools/pocket/build_rom.py guwange ~/Downloads build/roms --regions
# build/roms/guwange_prog.bin, _eeprom.bin, _ymz.bin, _layer0.bin, ...
```

## On the Analogue Pocket

Copy the image onto the SD card as

```
Assets/cave68000/common/<rom id>.rom        e.g. Assets/cave68000/common/ddonpach.rom
```

Each game's instance JSON, in `Assets/cave68000/frazilpop.Cave 68000/` (the
other versions' in `_alternatives/` there), points at that file and tells the
board which game it is. The Pocket loads the file at bridge address 0, and byte *n* of the
file ends up at SDRAM byte *n*. DonPachi's five instance JSONs also pick
the second bitstream, `donpachi.rbf_r`, which has its two OKI M6295s and the
NMK112 in place of the YMZ280B.

The EEPROM games keep their settings in a `.sav` per set on the card: the
93C46's 128 bytes, big-endian, as the zip's EEPROM file has them (MAME's
own `.nv` has each pair of bytes swapped). A set with no `.sav` starts from
the factory EEPROM in its image.

`deploy.sh` copies `pocket/dist` and the images in `build/pocket` onto the
card, checks every copy, and leaves the card mounted. It only copies a
bitstream that `pocket/build.sh` recorded as meeting timing.

## Checking against MAME

Everything from here on is for working on the core itself.

Run these through `mame_oracle.sh`. It gives each run a fresh, empty nvram and
cfg folder. MAME saves the 93C46 EEPROM when it quits and loads it again when
it starts, so otherwise every run would start from wherever the last one left
off. It also adds the flags autoboot needs (`-skip_gameinfo -autoboot_delay
0`) and `-norotate`, so the vertical games come out as the board draws them,
320 × 240 on their side. MAME reads the sets from `build/mame/roms`, where
`verify_rom.py --stage` puts them; `ROMS=` changes where it looks and `MAME=`
changes which MAME it runs. Anything after `--` goes to MAME.

### What's on screen at a given frame

```sh
tools/pocket/mame_oracle.sh tools/mame_cave_dump.lua ddonpach \
    DUMP_DIR=build/mame/dump/ddonpach DUMP_FRAME=600,1800
tools/pocket/mame_oracle.sh tools/mame_cave_screens.lua ddonpach \
    SCREENS_DIR=build/mame/screens/ddonpach FROM=1 TO=10800 STEP=60
```

`mame_cave_dump.lua` saves the board's video state with MAME's picture. Ask
for one frame and it writes straight into `DUMP_DIR`. Ask for several and
each gets its own `f<NNNNN>/` folder. The top of the script lists every file
it writes and what's in it. `mame_cave_screens.lua` saves only the
pictures, one for every `STEP` frames.

`PRESS` holds inputs down over frame ranges, by MAME's names for them:
`PRESS="400-405:Coin 1,600-605:1 Player Start"`. The harness's `--press`
takes the same list.

If you're looking for something in ddonpach's attract mode, roughly: the
warning at frame 180–1800 (first boot only), ranking 1860, Atlus logo 2400,
Cave logo 2580, title 2820, first demo (stage 1) 3600–6000, and the loop
again with stage 2's demo from 8040 and stage 3's from 12360.

### Which frame is which

Frame *N* is the *N*th frame notification since power-on, falling at
*N* × 17,376 µs. Everything is captured inside that notification, which MAME
sends just after it has drawn picture *N* and before the CPU carries on:

| file | what it shows |
|---|---|
| palette, layer VRAM, line RAM and registers, live sprite RAM, work RAM | the moment picture *N* was drawn – the layers came from exactly these bytes |
| `spriteram_at_draw.bin`, `videoregs_at_draw.bin` | sprite RAM and the 013's registers as it drew picture *N*'s sprites, at the vblank interrupt before picture *N* (90 µs before it on ddonpach, 100 on feversos and dfeveron, 2,000 on the rest), taken at the 68000's first interrupt acknowledge after the draw |
| `sprite_bitmap.bin` | the sprite layer mixed into picture *N* (priority, colour and pen per pixel) |
| `screen.png` | picture *N* |

The first sprite draw is in frame 2, and while a game boots with interrupts
off there is no acknowledge, so those frames have no `*_at_draw` files
(ddonpach: frames 1–129).

Don't use `screen:pixels()` to get the picture. Inside a frame notification
it gives you picture *N* − 1, because MAME swaps its two screen bitmaps after
drawing. Both scripts use `screen:snapshot()`, which is picture *N*.

### Drawing MAME's frames on the board

```sh
sim/ddonpach/build.sh
python3 tools/pocket/replay_cave_dumps.py ddonpach build/mame/dump/ddonpach --out build/sim/replay --png
```

`replay_cave_dumps.py` builds, for each dumped frame, a 68000 program that
copies MAME's state into the board through its own bus
(`cave_dump_loader.py`), runs the harness on it, and compares what the board
draws with MAME's picture and sprite layer, pixel for pixel. `--png` writes
sim | MAME | difference for any frame that differs. `--mame-budget` cuts each
sprite list where MAME's sprite chip runs out of time, so the frames MAME
cut compare too. `--pocket` runs the board on the Pocket's own memory
controllers and models of the parts instead (`sim/ddonpach/build.sh
--pocket`). For DonPachi's sets, build with `--oki`.

`diff_cave_frame.py` compares the harness's frames with MAME's pictures:
the same frame (`--shift K` for an offset), the nearest within `--window W`
frames, or `--match` for the closest picture anywhere in MAME's dumps.

### Tracing the bus from power-on

```sh
tools/pocket/mame_oracle.sh tools/mame_cave_bus_trace.lua ddonpach \
    BUS_TRACE_OUT=build/mame/ddonpach_bus.txt BUS_TRACE_COUNT=200000
python3 -I tools/pocket/diff_cave_trace.py ours.txt build/mame/ddonpach_bus.txt ddonpach
python3 -I tools/pocket/diff_cave_trace.py --census build/mame/ddonpach_bus.txt ddonpach
```

The traces are Mille Miglia's format (`addr R|W data mask`, plus `# frame N`
lines that the readers skip). The script starts at machine time 0, before
the 68000's first cycle, so there's no need to fake a reset.
`BUS_TRACE_DATA_ONLY=1` leaves out instruction fetches but keeps the vector
table, so resets and interrupts still show. fx68k and MAME's 68000 prefetch
differently, so `diff_cave_trace.py` compares what has to agree – every
write, every read outside the program ROM and every vector fetch – in order.

`mame_cave_sprite_load.lua` writes one line a frame of how much the sprite
chip drew (`LOAD_OUT=`, `FRAMES=`), for sizing the memory traffic.

### The harness

```sh
sim/ddonpach/build.sh                 # build/obj_ddonpach/tb_ddonpach
sim/ddonpach/build.sh --pocket        # build/obj_pocket/tb_pocket, on the Pocket's memories
sim/ddonpach/build.sh --oki           # DonPachi's board, build/obj_donpachi/tb_ddonpach
build/obj_ddonpach/tb_ddonpach build/pocket/ddonpach.rom 1 3600 build/sim/ddonpach 600,1800,3000
```

Run it from the repository root (fx68k loads its microcode from there). The
arguments are the image, the game id (0 feversos and dfeveron, 1 ddonpach,
2 donpachi, 3 esprade, 4 uopoko, 5 guwange, 6 gaia and theroes), the frames
to run, where to write, and the frames to save as `frame_NNNNN.ppm`.
`stats.csv` gets a line a frame. `--trace` writes the bus in the Lua
script's format, `--press` takes inputs as above (with `Pause`, the
Pocket's menu, too), `--wav` writes the sound, and `--prog` / `--replay` are
what `replay_cave_dumps.py` uses. The top of `tb_ddonpach.cpp` lists every
option.

### The sound

```sh
tools/pocket/mame_oracle.sh tools/mame_cave_ymz.lua ddonpach \
    YMZ_OUT=build/mame/ymz/ddonpach.txt YMZ_FRAMES=3000 \
    -- -sound none -samplerate 88200 -wavwrite build/mame/ymz/ddonpach.wav
sim/ymz280b/build.sh
```

`mame_cave_ymz.lua` logs everything the 68000 tells the YMZ280B, and when.
`sim/ymz280b` builds two benches: `model_vs_mame` plays the log through a
port of MAME's own chip (`ymz280b_mame.h`) and checks it against MAME's WAV,
and `tb_ymz280b` plays it through the board's chip and checks it against the
port, sample for sample (`--on-begin` lines up chosen writes with a sample,
as the whole board can; `--against` compares with another WAV, such as the
whole board's). `tb_ddonpach --ymz-log` writes the board's own log in the
same format, so a whole-board run can be played back through MAME's chip
(`model_vs_mame --true-rate`); `--ymz-trace` shows when each write landed.

DonPachi's two OKI M6295s and the NMK112 work the same way:

```sh
tools/pocket/mame_oracle.sh tools/mame_cave_oki.lua donpachi \
    OKI_OUT=build/mame/oki/donpachi.txt OKI_FRAMES=3000 -- -sound none
python3 -I tools/pocket/oki_model.py build/mame/oki/donpachi.txt \
    build/pocket/donpachi.rom --out build/mame/oki/donpachi_model
sim/oki/build.sh
```

`oki_model.py` is a port of MAME's chips that plays the log on the image's
samples (`--lazy-banks` switches the NMK112's banks when MAME really does,
at the chip's next update rather than at the write; `--wav` mixes the two
chips as MAME does). `sim/oki`'s `tb_oki` plays the same log through the
board's `SoundOki` and writes each chip's samples in the model's format, so
`cmp` says whether they are MAME's. On the whole board,
`tb_ddonpach --oki-log` and `--oki-samples` (built with `--oki`) do the same
for a run of the game. `sh pocket/build.sh --oki` builds DonPachi's
bitstream.

### The 48 kHz resampler

```sh
python3 tools/pocket/audio_fir.py --response
sim/audio/build.sh
build/obj_audio/tb_resample board.wav shell.wav
python3 tools/pocket/audio_check.py board.wav shell.wav
```

The board makes its sound at the YMZ280B's rate (88,200 Hz; 83,333 on gaia
and theroes, with `--16m`), and the shell filters it and takes 48 kHz
samples off it for the Pocket. `audio_fir.py` makes the filter's table and
prints its response. `tb_resample` plays a WAV of the board's sound
(`tb_ddonpach --wav`) through the shell's resampler, and `audio_check.py`
holds the result against scipy's resampler: the error below 16 kHz, and
anything folded down from above 24 kHz.
