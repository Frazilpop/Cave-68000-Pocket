-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cave 68000 (Pocket): MAME's picture for every frame in a range, as PNGs.
--   tools/pocket/mame_oracle.sh tools/mame_cave_screens.lua ddonpach \
--       SCREENS_DIR=build/mame/screens/ddonpach FROM=1 TO=10800 STEP=60
-- Frame N is the Nth frame notification from power-on, as in
-- mame_cave_dump.lua, and the picture is screen:snapshot() (not pixels(),
-- which lags a frame inside the notifier). The vertical games come out as
-- the board draws them, 320 x 240 on their side.
--
-- PRESS holds inputs down over frame ranges, by MAME's field names on IN0
-- and IN1 – "400-405:Coin 1,600-605:1 Player Start" – each held from the
-- first frame's notification to the last one's (sim/ddonpach's --press takes
-- the same list).
local DIR  = os.getenv("SCREENS_DIR") or "."
local FROM = tonumber(os.getenv("FROM") or "1")
local TO   = tonumber(os.getenv("TO") or "600")
local STEP = tonumber(os.getenv("STEP") or "1")
local scr  = manager.machine.screens[":screen.0"]
local presses = {}
for a, b, name in string.gmatch(os.getenv("PRESS") or "", "(%d+)-(%d+):([^,]+)") do
  local field
  for _, port in pairs(manager.machine.ioport.ports) do
    field = field or port.fields[name]
  end
  if not field then error("no input called " .. name) end
  table.insert(presses, { from = tonumber(a), to = tonumber(b), field = field })
end
os.execute('mkdir -p "' .. DIR .. '"')
local n = 0
cave_screens_notifier = emu.add_machine_frame_notifier(function()
  n = n + 1
  for _, p in ipairs(presses) do
    p.field:set_value((n >= p.from and n <= p.to) and 1 or 0)
  end
  if n >= FROM and n <= TO and ((n - FROM) % STEP) == 0 then
    scr:snapshot(string.format("%s/m%05d.png", DIR, n))
  end
  if n >= TO then manager.machine:exit() end
end)
