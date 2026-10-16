-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cave 68000 (Pocket): record Air Gallet's and Sailor Moon's sound board –
-- what the Z80 reads and writes on its I/O ports (the YM2151, the two OKI
-- M6295s, their banks, the sound latch), its RAM and banked ROM traffic,
-- and the 68000's side of the latch – as the oracle for the board's sound
-- CPU and for the chips: a model plays the YM2151 and OKI lines back
-- through MAME's own chips, sim/ddonpach records the board's side.
--
--   tools/pocket/mame_oracle.sh tools/mame_cave_z80.lua agallet \
--       Z80_OUT=build/mame/z80/agallet.txt Z80_FRAMES=3000 -- -sound none
--
-- Format, one line per access:
--     <machine time, s> Z <R|W> <port:02x> <data:02x>    Z80 I/O
--     <machine time, s> M <R|W> <addr:04x> <data:02x>    Z80 memory, 4000-ffff
--                                                        (Z80_MEM=1 only)
--     <machine time, s> C <R|W> <addr:06x> <data:04x>    68000 at b8006c-b8006f
--     # frame N <machine time, s>                        MAME's frame notifier
-- The time is the accessing CPU's own (the scheduler's time inside a tap is
-- the executing CPU's local time). The two CPUs run in turns, so a Z line
-- and a C line close together may be logged out of time order.
--
-- cave.cpp's sailormn_sound_portmap: 00 ROM bank, 10 reply to the 68000
-- (a 32-entry FIFO), 20 flags (reads 0), 30/40 the latch's low/high byte,
-- 50/51 YM2151, 60 OKI 0, 70 OKI 0's two banks, 80 OKI 1, c0 OKI 1's banks.
--
-- Environment:
--   Z80_OUT      output file (default cave_z80.txt)
--   Z80_FRAMES   frames to run (default 3000)
--   Z80_MEM      1 = also log the Z80's memory accesses at 4000-ffff
--   PRESS        inputs held over frame ranges, as tools/mame_cave_screens.lua
--                takes them ("400-405:Coin 1,600-605:1 Player Start")
--
-- Taps and notifiers are GLOBALS: a local is collected and the callback stops
-- with no error. The file is streamed.

local FRAMES = tonumber(os.getenv("Z80_FRAMES") or "3000")
local OUT    = os.getenv("Z80_OUT") or "cave_z80.txt"
local MEM    = (os.getenv("Z80_MEM") or "0") ~= "0"

local mach  = manager.machine
local main  = mach.devices[":maincpu"].spaces["program"]
local z80   = mach.devices[":audiocpu"]
local iosp  = z80.spaces["io"]
local prog  = z80.spaces["program"]
local romname = emu.romname()

local presses = {}
for a, b, name in string.gmatch(os.getenv("PRESS") or "", "(%d+)-(%d+):([^,]+)") do
  local field
  for _, port in pairs(mach.ioport.ports) do
    field = field or port.fields[name]
  end
  if not field then error("no input called " .. name) end
  table.insert(presses, { from = tonumber(a), to = tonumber(b), name = name, field = field })
end

local fh = assert(io.open(OUT, "w"))
local fmt = string.format
local frames, lines = 0, 0
fh:write(fmt("# %s\n", romname))

local function put(s)
  fh:write(s); lines = lines + 1
  if (lines & 0x3fff) == 0 then fh:flush() end
end

_G.cave_z80_taps = {
  iosp:install_read_tap(0x00, 0xff, "cave_z80_ior", function(offset, data, mask)
    put(fmt("%.12f Z R %02x %02x\n", mach.time:as_double(), offset & 0xff, data & 0xff))
  end),
  iosp:install_write_tap(0x00, 0xff, "cave_z80_iow", function(offset, data, mask)
    put(fmt("%.12f Z W %02x %02x\n", mach.time:as_double(), offset & 0xff, data & 0xff))
  end),
  main:install_read_tap(0xb8006c, 0xb8006f, "cave_z80_cr", function(offset, data, mask)
    put(fmt("%.12f C R %06x %04x\n", mach.time:as_double(), offset, data & 0xffff))
  end),
  main:install_write_tap(0xb8006c, 0xb8006f, "cave_z80_cw", function(offset, data, mask)
    put(fmt("%.12f C W %06x %04x\n", mach.time:as_double(), offset, data & 0xffff))
  end),
}
if MEM then
  table.insert(_G.cave_z80_taps, prog:install_read_tap(0x4000, 0xffff, "cave_z80_mr", function(offset, data, mask)
    put(fmt("%.12f M R %04x %02x\n", mach.time:as_double(), offset, data & 0xff))
  end))
  table.insert(_G.cave_z80_taps, prog:install_write_tap(0x4000, 0xffff, "cave_z80_mw", function(offset, data, mask)
    put(fmt("%.12f M W %04x %02x\n", mach.time:as_double(), offset, data & 0xff))
  end))
end

_G.cave_z80_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  local down = {}
  for _, p in ipairs(presses) do
    down[p.name] = down[p.name] or (frames >= p.from and frames <= p.to)
  end
  for _, p in ipairs(presses) do p.field:set_value(down[p.name] and 1 or 0) end
  fh:write(fmt("# frame %d %.12f\n", frames, mach.time:as_double()))
  if frames >= FRAMES then
    for _, t in ipairs(_G.cave_z80_taps) do t:remove() end
    fh:close()
    print(fmt("z80: %s, %d lines in %d frames (%.3f s) -> %s",
              romname, lines, frames, mach.time:as_double(), OUT))
    mach:exit()
  end
end)
