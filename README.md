![Cave 68000 banner](pocket/art/cave68000-banner.png)

# Cave 68000 for the Analogue Pocket

**DonPachi, DoDonPachi, ESP Ra.De., Guwange and more, now on the Analogue
Pocket!**

This core recreates the board these games all run on – The Cave 68000. It
plays eight games in total.

## Supported ROMs

| ROM id | game | notes |
| --- | --- | --- |
| `donpachi` | DonPachi (1995) | The US release |
| `ddonpach` | DoDonPachi (1997) | The world release |
| `esprade` | ESP Ra.De. (1998) | The world release, the International Ver. |
| `dfeveron` | Dangun Feveron (1998) | The Japanese release |
| `uopoko` | Puzzle Uo Poko (1998) | The world release |
| `guwange` | Guwange (1999) | The 1999 Master Ver. |
| `gaia` | Gaia Crusaders (1999) | By Noise Factory |
| `theroes` | Thunder Heroes (2001) | By Primetek |

### Other versions

Regional releases and revisions of the games above. On the Analogue
Pocket they're added to the `_alternatives` folder, which is next to the
main games.

| ROM id | game | notes |
| --- | --- | --- |
| `donpachij` | DonPachi (1995) | The Japanese release |
| `donpachijs` | DonPachi (1995) | Japan, the "Satsuei" version |
| `donpachikr` | DonPachi (1995) | The Korean release |
| `donpachihk` | DonPachi (1995) | The Hong Kong release |
| `ddonpachj` | DoDonPachi (1997) | The Japanese release |
| `espradej` | ESP Ra.De. (1998) | Japan, the 4/21 Master Ver. |
| `espradejo` | ESP Ra.De. (1998) | Japan, the earlier 4/14 Master Ver. |
| `feversos` | Fever SOS (1998) | Dangun Feveron's world release |
| `uopokoj` | Puzzle Uo Poko (1998) | The Japanese release |
| `guwanges` | Guwange (2000) | The 2000 Special Ver. |
| `theroesa` | Thunder Heroes (2001) | The second set |

## Installation

No game data comes with this core – you will need to supply your own MAME ROM
sets (`ddonpach.zip`, `esprade.zip` etc). For a clone, like `ddonpachj`, you
also need its parent's zip, unless your set is merged.

### Make the game files

You can't just drag and drop your MAME files. The Analogue Pocket can't read
zips, and the core needs each game as one file with every chip in its correct
place. There's a script in the repository that puts this all together for you,
or you can use a tool like Pocket Updater.

1. Download this repository (**Code → Download ZIP**, then unzip it) or clone it. You'll need Python 3 to run the build script.
2. Put your MAME zips in a folder.
3. In a terminal, from the repository's folder, run the script with the ROM ids you want from the tables above, separated by commas (or `all` for every one your zips have):
   
   ```sh
   python3 tools/pocket/build_rom.py ddonpach,esprade ~/path/to/roms build/pocket
   ```
   
   So this will write `build/pocket/ddonpach.rom` and `build/pocket/esprade.rom`. The script finds the right chips in whatever zips you have, merged or split, and checks them against MAME's checksums.

[`tools/pocket/README.md`](tools/pocket/README.md) includes more info on this.

### Copy to the Pocket

1. Copy the `Cores`, `Platforms` and `Assets` folders from a release onto your Pocket's SD card.
2. Copy your `.rom` files into `Assets/cave68000/common/` – for example `Assets/cave68000/common/ddonpach.rom`.
3. On the Pocket: openFPGA → Arcade → Cave 68000, and pick your rom.

## Controls

| Input | Action |
| --- | --- |
| D-pad | move |
| A | shot (button 1) |
| B | bomb (button 2) |
| X | button 3 |
| Y | button 4 (Gaia Crusaders and Thunder Heroes) |
| R | rapid shot – the same as quickly tapping the A button |
| Select | insert coin |
| Start | start |

Opening the Analogue Pocket menu will pause the game.

This includes usual **Display Mode** and **Controls** entries. Under **Core
Settings** there are three options:

- **Test Mode** – the arcade cabinet's operator menu, where you can set the difficulty, lives etc. Most of the games keep these settings on the SD card. Note that this is a button on the Cave 68000 and selecting this option is the equivalent of pressing this button.
- **Reset Game**
- **Diagnostic overlay** – probably best to ignore this

## A note on Slowdown

When the screen fills with bullets, the game slows down. This is a 'feature'
not a bug.  It's not an issue with the core, but rather exactly how the 68000
board works, and the games are balanced around it. In DoDonPachi especially,
there are walls of bullets that are only dodgeable because the game slows
down for them. Run them at full speed and it would be a different, even
harder game.

The core slows down on the same frames as the original board, and no more.
This has been measured frame for frame in simulation.

## Technical details

- The core recreates Cave's first-generation 68000 board in hardware logic, built on [nullobject's Cave MiSTer core](https://github.com/MiSTer-devel/Arcade-Cave_MiSTer) with a Pocket shell. DonPachi's sound chips have their own bitstream.
- It's been checked against MAME in simulation – the main processor's moves identical from power-on, MAME's pictures redrawn pixel for pixel, and the sound equal to MAME's on every sample.
- To build it yourself: `tools/bootstrap.sh`, then `sh pocket/build.sh` and `sh pocket/build.sh --oki` for DonPachi's bitstream (Quartus Prime Lite 21.1 in Docker, about ten minutes each). The finished SD card layout can be found in `pocket/dist/`.

## Credits and licence

- **Josh Bassett (nullobject)** – the Cave MiSTer core this is built on, which grew from **Rick Wertenbroek**'s reverse engineering of DoDonPachi.
- **Jorge Cwik (ijor)** – fx68k, the 68000 processor.
- **alphanu1** – the SDRAM controller.
- **agg23** – the Pocket utilities used for loading and audio.
- **Analogue** – the openFPGA core framework.
- **The MAME team** – whose work on the Cave boards and their sound chips was referenced.
- Pocket port by **Frazilpop**.

GPL-3.0-only. [`THIRD-PARTY.md`](THIRD-PARTY.md) lists every dependency and its
licence.

DonPachi, DoDonPachi, ESP Ra.De., Guwange, Dangun Feveron and Uo Poko are ©
Cave, Gaia Crusaders is © Noise Factory and Thunder Heroes is © Primetek
Investments. This project contains no game data.
