-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cave 68000 (Pocket): record what the 68000 tells the YMZ280B, and when, as
-- the oracle for the sound: tools/pocket/ymz280b_model.py plays the log back
-- through MAME's chip (ported), sim/ymz280b plays it through the board's.
--
--   tools/pocket/mame_oracle.sh tools/mame_cave_ymz.lua ddonpach \
--       YMZ_OUT=build/mame/ymz/ddonpach.txt YMZ_FRAMES=3000 \
--       -- -sound none -samplerate 88200 -wavwrite build/mame/ymz/ddonpach.wav
--
-- Format, one line per access the chip sees:
--     <machine time, s> W <register:02x> <data:02x>   a data write
--     <machine time, s> S <status:02x>                 a status read, as MAME
--                                                      answered it
--     # frame N <machine time, s>                      MAME's frame notifier
-- The time is the 68000's own (the scheduler's time inside a tap is the
-- executing CPU's local time), which is when MAME brings the chip's stream up
-- to date before it takes the write. Register-select writes are folded into
-- the data lines; reads of the external memory port are not on this board.
--
-- Environment:
--   YMZ_OUT      output file (default cave_ymz.txt)
--   YMZ_FRAMES   frames to run (default 3000)
--
-- Taps and notifiers are GLOBALS: a local is collected and the callback stops
-- with no error. The file is streamed.

local FRAMES = tonumber(os.getenv("YMZ_FRAMES") or "3000")
local OUT    = os.getenv("YMZ_OUT") or "cave_ymz.txt"

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local romname = emu.romname()

-- where cave.cpp maps the chip: 300000-300003 on every set of this board but
-- guwange's, which has it at 800000
local BASE = { guwange = 0x800000, guwanges = 0x800000 }
local base = BASE[romname] or 0x300000

local fh = assert(io.open(OUT, "w"))
local fmt = string.format
local frames, writes, reg = 0, 0, 0
fh:write(fmt("# %s\n", romname))

_G.cave_ymz_w = space:install_write_tap(base, base + 3, "cave_ymz_w",
  function(offset, data, mask)
    if (mask & 0x00ff) == 0 then return end
    local b = data & 0xff
    if (offset & 2) == 0 then
      reg = b
    else
      writes = writes + 1
      fh:write(fmt("%.12f W %02x %02x\n", mach.time:as_double(), reg, b))
    end
  end)
_G.cave_ymz_r = space:install_read_tap(base, base + 3, "cave_ymz_r",
  function(offset, data, mask)
    if (mask & 0x00ff) == 0 or (offset & 2) == 0 then return end
    fh:write(fmt("%.12f S %02x\n", mach.time:as_double(), data & 0xff))
  end)

_G.cave_ymz_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  fh:write(fmt("# frame %d %.12f\n", frames, mach.time:as_double()))
  if frames >= FRAMES then
    _G.cave_ymz_w:remove(); _G.cave_ymz_r:remove()
    fh:close()
    print(fmt("ymz: %s, %d register writes in %d frames (%.3f s) -> %s",
              romname, writes, frames, mach.time:as_double(), OUT))
    mach:exit()
  end
end)
