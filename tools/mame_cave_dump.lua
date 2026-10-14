-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cave 68000 (Pocket): dump the board's video state at chosen frames, with
-- MAME's own picture of each, as the oracle for the RTL.
--
--   tools/pocket/mame_oracle.sh tools/mame_cave_dump.lua ddonpach \
--       DUMP_DIR=build/mame/dump/ddonpach DUMP_FRAME=600,1800
--
-- Environment:
--   DUMP_DIR    output directory. One frame: files go straight in it. Several
--               (DUMP_FRAME=600,1800,...): one subdirectory f<NNNNN> each.
--   DUMP_FRAME  frame number(s), counted as MAME frame notifications from
--               power-on: frame 1 is the first picture MAME renders.
--   DUMP_SET    optional; checked against the running set.
--
-- Files (16-bit data as little-endian u16 words, as Mille Miglia's dumps):
--   palette.bin          the palette RAM (0x8000 xGRB_555 entries; 0x800 on
--                        feversos/dfeveron and donpachi)
--   layer<N>_vram16.bin  038 chip N: the 16 x 16 tile map (0x0000-0x0fff)
--   layer<N>_line.bin    line RAM, row-scroll / row-select (0x1000-0x17ff)
--   layer<N>_scratch.bin the scratch RAM (0x1800-0x3fff)
--   layer<N>_vram8.bin   the 8 x 8 tile map (0x4000-0x7fff; ddonpach's and
--                        donpachi's layer 2 has only this, 0x4000 bytes)
--   layer<N>_regs.bin    the chip's three control words
--   videoregs.bin        the 013's 64 registers (the bus maps them write-only:
--                        a read there is the IRQ cause)
--   spriteram.bin        all of sprite RAM (four 0x4000 banks), live
--   spriteram_at_draw.bin  all of sprite RAM as the 013 drew this picture's
--                        sprites from it (see below)
--   videoregs_at_draw.bin  the 013's registers at the same instant
--   sprite_bitmap.bin    the 013's output composited into this picture:
--                        320 x 240 u16 (rows to the screen's height), 0 =
--                        transparent, else colour code << 8 | pen with the
--                        priority in bits 14-15 ((attr & 0x30) << 10 |
--                        (attr & 0x3f00) | pen)
--   workram.bin          the 68000's 64 KB of work RAM
--   screen.png           MAME's picture of this frame (screen:snapshot)
--   frame.json           frame numbers, times, the draw, the bank drawn, the
--                        layers' state
--
-- WHICH FRAME IS WHICH
--
-- Everything is captured in the frame notifier, which MAME calls from
-- video_manager::frame_update() in screen_device::vblank_begin(), after
-- finish_screen_updates() has rendered picture N and before any CPU runs
-- again. The screen has no vblank time (set_vblank_time(0)), so notifier N
-- falls at N x 17376 µs. For frame N:
--
--   * palette, VRAM, line RAM, layer and sprite registers, live sprite RAM,
--     work RAM: the state at the instant picture N was rendered. The
--     layers of picture N were drawn from exactly these bytes (cave.cpp
--     updates the screen once a frame).
--   * Sprites: the 013 does not draw at the picture. cave_state::interrupt
--     runs at each vblank and arms m_int_timer for 17376 µs minus
--     m_time_vblank_irq (90 µs on ddonpach, 100 on feversos/dfeveron, 2000
--     on the rest); vblank_start then draws the list (get_sprite_info, the
--     bank in videoregs[4] & 3) into m_sprite_bitmap and raises the vblank
--     IRQ. So picture N's sprites were drawn m_time_vblank_irq before
--     picture N, from sprite RAM as it stood then. No CPU runs between the
--     draw and the IRQ being raised; the first level-1 acknowledge after it
--     (the autovector read at 000064, tapped here) is the earliest point a
--     script can see, and spriteram_at_draw.bin / videoregs_at_draw.bin are
--     taken there. frame.json gives the delay; a long one (the 68000 still
--     in a level-1 handler) would let the game write sprite RAM first.
--     The first draw is in frame 2 (MAME arms the timer at the first vblank),
--     so picture 1 has no sprites. While the boot runs with interrupts
--     masked there is no acknowledge, and those frames have no *_at_draw
--     files (ddonpach: frames 1-129).
--   * sprite_bitmap.bin is m_sprite_bitmap read at notifier N: the sprite
--     layer composited into picture N.
--   * screen.png: screen:snapshot() renders the screen texture, which
--     video_output_update() has just pointed at picture N — so it IS picture
--     N. (Not screen:pixels(): inside a notifier that returns picture N-1.)

local DIR = os.getenv("DUMP_DIR") or "."
local SET = os.getenv("DUMP_SET")
if DIR:sub(1, 1) ~= "/" then DIR = (os.getenv("PWD") or ".") .. "/" .. DIR end

local FRAMES, WANT = {}, {}
for s in (os.getenv("DUMP_FRAME") or "600"):gmatch("[^,]+") do
  local n = assert(tonumber(s), "bad DUMP_FRAME")
  FRAMES[#FRAMES + 1] = n; WANT[n] = true
end
table.sort(FRAMES)
local LAST = FRAMES[#FRAMES]

local mach    = manager.machine
local romname = emu.romname()
assert(not SET or SET == romname, "DUMP_SET=" .. tostring(SET) .. " but running " .. romname)

-- m_time_vblank_irq by set (cave.cpp's init_*): where the 013 draws.
local IRQ_US = { ddonpach = 90, ddonpachj = 90, feversos = 100, dfeveron = 100,
                 esprade = 2000, espradej = 2000, espradejo = 2000,
                 guwange = 2000, guwanges = 2000, uopoko = 2000, uopokoj = 2000,
                 gaia = 2000, theroes = 2000, theroesa = 2000,
                 donpachi = 90, donpachij = 90, donpachijs = 90, donpachikr = 90, donpachihk = 90 }
assert(IRQ_US[romname], "mame_cave_dump.lua is for the Cave 68000 board's sets, not " .. romname)
local FRAME_S = 0.017376

local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local scr   = mach.screens[":screen.0"]

local function item(tag, name)
  local dev = assert(mach.devices[tag], "no device " .. tag)
  local idx = dev.items[name]
  return idx and emu.item(idx)
end
local function need(tag, name) return assert(item(tag, name), "no save item " .. tag .. " " .. name) end

-- The work RAM is an anonymous share: the maincpu item named by its range.
local it_work
for name, idx in pairs(cpu.items) do
  if name:match("^0/%x+%-%x+$") then it_work = emu.item(idx); break end
end
assert(it_work, "no work RAM item")
local it_palette   = need(":maincpu", "0/:palette.0")
local it_spriteram = need(":maincpu", "0/:spriteram.0")
local it_videoregs = need(":spritegen.0", "0/:spritegen.0:videoregs")
local it_bitmap    = need(":spritegen.0", "0/m_sprite_bitmap")
local it_bank      = need(":spritegen.0", "0/m_spriteram_bank")
local layers = {}
for n = 0, 3 do
  if mach.devices[":tilemap." .. n] then
    local t = ":tilemap." .. n
    layers[#layers + 1] = { n = n,
      vram16  = item(":maincpu", "0/" .. t .. ":vram_16x16"),
      line    = item(":maincpu", "0/" .. t .. ":lineram"),
      scratch = item(":maincpu", "0/" .. t .. ":scratchpad"),
      vram8   = item(":maincpu", "0/" .. t .. ":vram_8x8"),
      regs    = need(t, "0/m_vregs"),
      tiledim = need(t, "0/m_tiledim") }
  end
end
local BM_W = it_bitmap.count // 512           -- 512 rows (512 x 512, any row padding)
assert(BM_W >= 512, "unexpected sprite bitmap size " .. it_bitmap.count)

-- ------------------------------------------------------------ writers
local outdir = DIR
local function words_le(get, n)
  local t, out = {}, {}
  for i = 0, n - 1 do
    local v = get(i)
    t[#t + 1] = string.char(v & 0xff, (v >> 8) & 0xff)
    if #t >= 4096 then out[#out + 1] = table.concat(t); t = {} end
  end
  out[#out + 1] = table.concat(t)
  return table.concat(out)
end
local function write(name, data)
  local f = assert(io.open(outdir .. "/" .. name, "wb"))
  f:write(data); f:close()
end
local function itm(name, it)
  if it then write(name, words_le(function(i) return it:read(i) end, it.count)) end
end
local function hexwords(it, n)
  local t = {}
  for i = 0, (n or it.count) - 1 do t[#t + 1] = string.format("%04x", it:read(i)) end
  return table.concat(t, " ")
end

-- --------------------------------------------------------------- state
local frame, last_notify = 0, 0.0
local draw = {}         -- [frame] = { time, ack, bank, spriteram, videoregs }

-- The level-1 autovector fetch: the first one at or after this frame's draw
-- time is the first instant after the 013 drew. (The boot's ROM checksum
-- reads 000064 too, a byte at a time; a vector fetch is a word.)
_G.cave_irq_tap = space:install_read_tap(0x000064, 0x000067, "cave_dump_irq",
  function(offset, data, mask)
    local f = frame + 1
    if draw[f] or frame < 1 or mask ~= 0xffff then return end
    local t_draw = last_notify + FRAME_S - IRQ_US[romname] * 1e-6
    local now = mach.time:as_double()
    if now + 1e-9 < t_draw then return end
    local d = { time = t_draw, ack = now, bank = it_bank:read(0) }
    if WANT[f] then
      d.spriteram = words_le(function(i) return it_spriteram:read(i) end, it_spriteram.count)
      d.videoregs = words_le(function(i) return it_videoregs:read(i) end, it_videoregs.count)
    end
    draw[f] = d
  end)

local function json_str(s) return '"' .. tostring(s):gsub('[%c"\\]', function(c)
  return string.format("\\u%04x", c:byte()) end) .. '"' end

local function dump_frame(n)
  outdir = (#FRAMES > 1) and string.format("%s/f%05d", DIR, n) or DIR
  os.execute('mkdir -p "' .. outdir .. '"')

  itm("palette.bin", it_palette)
  for _, L in ipairs(layers) do
    local p = "layer" .. L.n
    itm(p .. "_vram16.bin", L.vram16)
    itm(p .. "_line.bin", L.line)
    itm(p .. "_scratch.bin", L.scratch)
    itm(p .. "_vram8.bin", L.vram8)
    itm(p .. "_regs.bin", L.regs)
  end
  itm("videoregs.bin", it_videoregs)
  itm("spriteram.bin", it_spriteram)
  itm("workram.bin", it_work)
  local d = draw[n]
  if d and d.spriteram then
    write("spriteram_at_draw.bin", d.spriteram)
    write("videoregs_at_draw.bin", d.videoregs)
  end
  local h = scr.height
  write("sprite_bitmap.bin", words_le(function(i)
    return it_bitmap:read((i // 320) * BM_W + (i % 320)) end, 320 * h))
  local err = scr:snapshot(outdir .. "/screen.png")

  local f = assert(io.open(outdir .. "/frame.json", "w"))
  local function kv(k, v, last) f:write(string.format('  %s: %s%s\n', json_str(k), v, last and "" or ",")) end
  f:write("{\n")
  kv("set", json_str(romname))
  kv("frame", n)
  kv("screen_frame_number", scr:frame_number())
  kv("machine_time", string.format("%.9f", mach.time:as_double()))
  kv("captured_in", json_str("frame notifier N = vblank_begin of frame N, right after picture N was rendered"))
  kv("vblank_irq_us_before_frame_end", IRQ_US[romname])
  if d then
    kv("sprite_draw_time", string.format("%.9f", d.time))
    kv("sprite_draw_ack_delay_us", string.format("%.3f", (d.ack - d.time) * 1e6))
    kv("sprite_bank_drawn", d.bank)
    kv("spriteram_at_draw_reflects", json_str(string.format(
      "sprite RAM at the first level-1 acknowledge after the 013 drew picture %d's sprites (bank %d)", n, d.bank)))
  else
    kv("sprite_draw_time", "null")
    kv("sprite_bank_drawn", "null")
  end
  kv("sprite_bitmap_reflects", json_str(string.format(
    "m_sprite_bitmap at notifier %d = the sprite layer composited into picture %d", n, n)))
  kv("videoregs", json_str(hexwords(it_videoregs, 8)))
  for _, L in ipairs(layers) do
    kv("layer" .. L.n .. "_regs", json_str(hexwords(L.regs)))
    kv("layer" .. L.n .. "_tiledim", L.tiledim:read(0))
  end
  kv("picture", json_str("screen.png = picture " .. n .. (err and (" (snapshot error " .. tostring(err) .. ")") or "")))
  kv("width", scr.width); kv("height", h, true)
  f:write("}\n")
  f:close()
  print(string.format("dump: frame %d (screen frame %d) -> %s", n, scr:frame_number(), outdir))
end

_G.cave_dump_frame_sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if WANT[frame] then dump_frame(frame) end
  draw[frame - 1] = nil
  last_notify = mach.time:as_double()
  if frame >= LAST then mach:exit() end
end)
