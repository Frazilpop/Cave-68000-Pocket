-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cave 68000 (Pocket): record what DonPachi's 68000 tells its two OKI M6295s
-- and the NMK112, and when, as the oracle for the sound:
-- tools/pocket/oki_model.py plays the log back through MAME's chips (ported),
-- sim/ddonpach's --oki-log records the board's side of the same.
--
--   tools/pocket/mame_oracle.sh tools/mame_cave_oki.lua donpachi \
--       OKI_OUT=build/mame/oki/donpachi.txt OKI_FRAMES=3000 -- -sound none
--
-- Format, one line per access:
--     <machine time, s> W <chip> <data:02x>      a command byte to OKI 0 or 1
--     <machine time, s> S <chip> <status:02x>    a status read, as MAME answered
--     <machine time, s> N <offset> <data:02x>    an NMK112 bank write (0-7)
--     # frame N <machine time, s>                MAME's frame notifier
-- The time is the 68000's own (the scheduler's time inside a tap is the
-- executing CPU's local time), which is when MAME brings the chip's stream up
-- to date before it takes the write.
--
-- Environment:
--   OKI_OUT      output file (default cave_oki.txt)
--   OKI_FRAMES   frames to run (default 3000)
--   PRESS        inputs held over frame ranges, as tools/mame_cave_screens.lua
--                takes them ("400-405:Coin 1,600-605:1 Player Start")
--
-- Taps and notifiers are GLOBALS: a local is collected and the callback stops
-- with no error. The file is streamed.

local FRAMES = tonumber(os.getenv("OKI_FRAMES") or "3000")
local OUT    = os.getenv("OKI_OUT") or "cave_oki.txt"

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
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
local frames, writes = 0, 0
fh:write(fmt("# %s\n", romname))

-- cave.cpp's donpachi_map: b00000-b00003 OKI 0, b00010-b00013 OKI 1,
-- b00020-b0002f the NMK112, all on the low byte
_G.cave_oki_w = space:install_write_tap(0xb00000, 0xb0002f, "cave_oki_w",
  function(offset, data, mask)
    if (mask & 0x00ff) == 0 then return end
    local rel = offset - 0xb00000
    local t = mach.time:as_double()
    if rel < 0x04 then
      fh:write(fmt("%.12f W 0 %02x\n", t, data & 0xff)); writes = writes + 1
    elseif rel >= 0x10 and rel < 0x14 then
      fh:write(fmt("%.12f W 1 %02x\n", t, data & 0xff)); writes = writes + 1
    elseif rel >= 0x20 then
      fh:write(fmt("%.12f N %d %02x\n", t, ((rel - 0x20) >> 1) & 7, data & 0xff))
    end
  end)
_G.cave_oki_r = space:install_read_tap(0xb00000, 0xb00013, "cave_oki_r",
  function(offset, data, mask)
    if (mask & 0x00ff) == 0 then return end
    local rel = offset - 0xb00000
    local t = mach.time:as_double()
    if rel < 0x04 then
      fh:write(fmt("%.12f S 0 %02x\n", t, data & 0xff))
    elseif rel >= 0x10 then
      fh:write(fmt("%.12f S 1 %02x\n", t, data & 0xff))
    end
  end)

_G.cave_oki_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  local down = {}
  for _, p in ipairs(presses) do
    down[p.name] = down[p.name] or (frames >= p.from and frames <= p.to)
  end
  for _, p in ipairs(presses) do p.field:set_value(down[p.name] and 1 or 0) end
  fh:write(fmt("# frame %d %.12f\n", frames, mach.time:as_double()))
  if frames >= FRAMES then
    _G.cave_oki_w:remove(); _G.cave_oki_r:remove()
    fh:close()
    print(fmt("oki: %s, %d command bytes in %d frames (%.3f s) -> %s",
              romname, writes, frames, mach.time:as_double(), OUT))
    mach:exit()
  end
end)
