-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cave 68000 (Pocket): trace the 68000's first N bus accesses from power-on
-- on a set of this board, as the oracle for the board's own trace.
--
--   tools/pocket/mame_oracle.sh tools/mame_cave_bus_trace.lua ddonpach \
--       BUS_TRACE_OUT=build/mame/ddonpach_bus.txt BUS_TRACE_COUNT=200000
--
-- Compare with tools/pocket/diff_cave_trace.py (the maps per game).
--
-- Format, one access per line, as Mille Miglia's traces:
--     <addr:06x> <R|W> <data:04x> <mask:04x>
-- addr is the byte address of the 16-bit word (even), mask the lanes the
-- 68000 drove (ffff word, ff00 even byte, 00ff odd byte). Lines starting '#'
-- mark frame boundaries ("# frame N" = MAME's vblank_begin of frame N, the
-- instant picture N is rendered; 3 fields, so the diff's reader skips them).
--
-- Environment:
--   BUS_TRACE_OUT        output file (default cave_bus_trace.txt)
--   BUS_TRACE_COUNT      accesses to record (default 200000)
--   BUS_TRACE_FRAMES     stop after this many frames anyway (default 3000)
--   BUS_TRACE_DATA_ONLY  1 = skip instruction fetches: tap only the vector
--                        table (000000-0003ff, so resets and IRQs still show)
--                        and 100000-ffffff (nothing else on this board sits
--                        inside the 1 MB ROM window). Several times fewer Lua
--                        callbacks.
--
-- FROM POWER-ON, NO SYNTHETIC RESET
--
-- With -autoboot_delay 0, MAME 0.289 runs the autoboot script at machine
-- time 0, before the 68000 has executed a cycle (PC 0, frame 0). So the taps
-- go straight on, the first two accesses are the reset vector reads at
-- 000000/000002, and every RAM holds its power-on content (MAME zero-fills).
--
-- WHAT THIS BOARD RETURNS THAT A CORE MUST MATCH
--
--   One interrupt, level 1, autovectored: an IRQ shows as the two vector
--   reads at 000064/000066. There is no IACK cycle on the program bus. The
--   vblank source is raised m_time_vblank_irq before the frame's end (17376
--   µs frame; 90 µs on ddonpach, 100 on feversos/dfeveron, 2000 on the
--   others) — MAME arms it at each vblank, so the first one comes in frame 2.
--   The YMZ280B's IRQ is the same level.
--   irq cause (800000-800007 on most; 300000 guwange, 600000 uopoko): reads
--           0003 with bit 0 cleared while the vblank source is up and bit 1
--           while the unknown one is; offset 0 adds bit 2 = 1 except in the
--           2000 µs after the vblank IRQ. Reading offset 4 clears the vblank
--           source, offset 6 the unknown one. Timing-dependent by nature.
--   YMZ280B (300000-300003 odd bytes; 800000 guwange): status reads say
--           which channels ended — timing-dependent too.
--   IN1 (d00002 on ddonpach/esprade): bit 11 is the 93C46's data out.
--
-- Taps and notifiers are GLOBALS: a local is collected and the callback stops
-- with no error. The file is streamed, so a crashed run keeps what it had.

local MAX    = tonumber(os.getenv("BUS_TRACE_COUNT") or "200000")
local FRAMES = tonumber(os.getenv("BUS_TRACE_FRAMES") or "3000")
local OUT    = os.getenv("BUS_TRACE_OUT") or "cave_bus_trace.txt"
local DATA_ONLY = (os.getenv("BUS_TRACE_DATA_ONLY") or "0") ~= "0"

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local romname = emu.romname()

local fh = assert(io.open(OUT, "w"))
local n, done, frames = 0, false, 0
local t0 = os.clock()
local fmt = string.format

local function record(rw, offset, data, mask)
  if done then return end
  n = n + 1
  fh:write(fmt("%06x %s %04x %04x\n", offset & 0xffffff, rw, data & 0xffff, mask & 0xffff))
  if (n & 0x3fff) == 0 then fh:flush() end
  if n >= MAX then done = true end
end

local start_pc = cpu.state["PC"].value
print(fmt("bus trace: %s, script at machine time %.6f, PC %06x, %s",
          romname, mach.time:as_double(), start_pc, DATA_ONLY and "data only" or "all accesses"))

local ranges = DATA_ONLY and { { 0x000000, 0x0003ff }, { 0x100000, 0xffffff } }
                          or { { 0x000000, 0xffffff } }
_G.cave_taps = {}
for i, r in ipairs(ranges) do
  _G.cave_taps[#_G.cave_taps + 1] = space:install_read_tap(r[1], r[2], "cave_bt_r" .. i,
    function(offset, data, mask) record("R", offset, data, mask) end)
  _G.cave_taps[#_G.cave_taps + 1] = space:install_write_tap(r[1], r[2], "cave_bt_w" .. i,
    function(offset, data, mask) record("W", offset, data, mask) end)
end

-- Finishing happens here, never inside a tap: exiting from a tap tears the
-- machine down under the access in flight, and taps left installed keep
-- costing a Lua call per access after the limit.
_G.cave_bt_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if not done then fh:write(fmt("# frame %d\n", frames)) end
  if done or frames >= FRAMES then
    for _, t in ipairs(_G.cave_taps) do t:remove() end
    fh:flush(); fh:close()
    local secs = os.clock() - t0
    print(fmt("bus trace: %d accesses in %d frames (%.3f s emulated), %.1f s CPU -> %s",
              n, frames, mach.time:as_double(), secs, OUT))
    mach:exit()
  end
end)
