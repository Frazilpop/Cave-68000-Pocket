-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cave 68000 (Pocket): measure the 013's sprite load per frame — what the
-- sprite ROM port and the frame-buffer traffic have to carry.
--
--   tools/pocket/mame_oracle.sh tools/mame_cave_sprite_load.lua ddonpach \
--       LOAD_OUT=build/mame/load/ddonpach.csv FRAMES=15000
--
-- For every frame, walks the list the 013 drew (the bank in m_spriteram_bank)
-- as sprite013_device::draw_sprites does — both formats, the S.9.6 /
-- integer position switch, the zoom, the 10-bit wrap, MAME's sprite-clock
-- budget — and writes one CSV line:
--
--   frame       frame notification number (as mame_cave_dump.lua)
--   src         a = sprite RAM read at the first level-1 acknowledge after
--               the draw (as mame_cave_dump.lua's spriteram_at_draw.bin);
--               n = no acknowledge that frame (the 68000 had IRQs masked),
--               read at the notifier instead — the drawn bank is not
--               rewritten until the game flips banks, so the same list
--   bank        the bank drawn
--   entries     list entries with a non-zero size, all 1024 walked
--   tiles_all   16 x 16 blocks of every such entry: what upstream's
--               SpriteProcessor fetches (it skips only empty sizes, and has
--               no budget)
--   visible     entries MAME draws (on screen, before its budget runs out)
--   tiles_vis   16 x 16 blocks of those
--   tiles_on    blocks of those that put a pixel on the screen — what a
--               processor culling by block would fetch
--   px_on       source pixels of those that land on the screen: the
--               blitter's writes. The 013 never draws a pixel twice — a
--               source pixel i lands at x + floor(i * zoom / 256), so an
--               enlarged sprite has gaps, not more writes.
--   clk         MAME's sprite clock used (32 an entry, plus its source
--               pixels: every entry on the zoom format, on screen ones only
--               on ddonpach's)
--   cut         entries left when MAME's budget (448 x 272 x 2 clocks) ran
--               out; 0 = the whole list was drawn
--   lost        of those, entries that would have been on screen — what an
--               RTL without the budget draws and MAME does not
--   lost_tiles  their 16 x 16 blocks
--
-- A block is 128 bytes of sprite ROM at 4 bpp (ddonpach, feversos, uopoko,
-- gaia, theroes) and 256 at 8 bpp (esprade, guwange). At the end the script
-- prints, and writes beside the CSV as .txt, the median, 99th percentile and
-- maximum of each column over the frames with sprites on screen, with the
-- frame of each maximum.

local OUT    = os.getenv("LOAD_OUT") or "cave_sprite_load.csv"
local FRAMES = tonumber(os.getenv("FRAMES") or "15000")
if OUT:sub(1, 1) ~= "/" then OUT = (os.getenv("PWD") or ".") .. "/" .. OUT end
os.execute('mkdir -p "' .. OUT:match("^(.*)/") .. '"')

local mach    = manager.machine
local romname = emu.romname()
local GAME = {   -- m_time_vblank_irq (µs), sprite bpp, alt (no-zoom) format
  ddonpach  = { 90, 4, true },  ddonpachj = { 90, 4, true },
  feversos  = { 100, 4 },       dfeveron  = { 100, 4 },
  esprade   = { 2000, 8 },      espradej  = { 2000, 8 },  espradejo = { 2000, 8 },
  guwange   = { 2000, 8 },      guwanges  = { 2000, 8 },
  uopoko    = { 2000, 4 },      uopokoj   = { 2000, 4 },
  gaia      = { 2000, 4 },      theroes   = { 2000, 4 },  theroesa  = { 2000, 4 },
}
local G = assert(GAME[romname], "mame_cave_sprite_load.lua is for the YMZ280B Cave board, not " .. romname)
local IRQ_S, BPP, ALT = G[1] * 1e-6, G[2], G[3] or false
local FRAME_S = 0.017376
local MAX_CLK = 448 * 272 * 2           -- sprite013: visible width <= 360

local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local scr   = mach.screens[":screen.0"]
local MAX_X, MAX_Y = scr.width, scr.height
local function need(tag, name)
  return emu.item((assert(mach.devices[tag].items[name], "no save item " .. tag .. " " .. name)))
end
local it_spriteram = need(":maincpu", "0/:spriteram.0")
local it_videoregs = need(":spritegen.0", "0/:spritegen.0:videoregs")
local it_bank      = need(":spritegen.0", "0/m_spriteram_bank")

local function sext10(v) v = v & 0x3ff; return (v >= 0x200) and (v - 0x400) or v end

-- Source pixels i in [i0, i1) that land on [0, lim): pixel i goes to
-- p + floor(i * zoom / 256), which only grows with i.
local function ceil_div(a, b) return -((-a) // b) end
local function src_on(p, i0, i1, zoom, lim)
  if zoom == 0 then return (p >= 0 and p < lim) and (i1 - i0) or 0 end
  local lo = math.max(i0, ceil_div(-p * 256, zoom))
  local hi = math.min(i1, ceil_div((lim - p) * 256, zoom))
  return math.max(0, hi - lo)
end
-- Pixels on screen along one axis, and the 16-pixel blocks with any.
local function axis(p, n, zoom, lim)
  local px, blocks = 0, 0
  for c = 0, n - 1 do
    local k = src_on(p, c * 16, c * 16 + 16, zoom, lim)
    if k > 0 then px = px + k; blocks = blocks + 1 end
  end
  return px, blocks
end

local function measure()
  local bank = it_bank:read(0)
  local base = bank * 0x2000             -- words
  local integer_pos = (it_videoregs:read(5) & 0x3000) == 0
  local entries, tiles_all, visible, tiles_vis, tiles_on, px_on = 0, 0, 0, 0, 0, 0
  local clk, cut, lost, lost_tiles = 0, 0, 0, 0
  local over = false                     -- MAME's budget has run out
  for i = 0, 1023 do
    local w = base + i * 8
    if not over then
      clk = clk + 32
      if clk > MAX_CLK then over = true; cut = 1024 - i end
    end
    local x, y, attr, size, zx, zy
    if ALT then
      attr = it_spriteram:read(w)
      x, y = it_spriteram:read(w + 2), it_spriteram:read(w + 3)
      size = it_spriteram:read(w + 4)
      zx, zy = 0x100, 0x100
    else
      x, y = it_spriteram:read(w), it_spriteram:read(w + 1)
      attr = it_spriteram:read(w + 2)
      zx, zy = it_spriteram:read(w + 4), it_spriteram:read(w + 5)
      size = it_spriteram:read(w + 6)
    end
    local cols, rows = (size >> 8) & 0x1f, size & 0x1f
    if cols > 0 and rows > 0 then
      entries = entries + 1
      tiles_all = tiles_all + cols * rows
      local tw, th = cols * 16, rows * 16
      local tot_w, tot_h = tw, th
      if ALT then
        x, y = sext10(x), sext10(y)
      else
        if not over then
          clk = clk + tw * th            -- charged before the visibility test
          if clk > MAX_CLK then over = true; cut = 1024 - i end
        end
        local flipx, flipy = (attr & 8) ~= 0, (attr & 4) ~= 0
        local tot_wf, tot_hf = tw * zx, th * zy
        tot_w, tot_h = tot_wf // 0x100, tot_hf // 0x100
        if integer_pos then x = (x & 0x3ff) << 8; y = (y & 0x3ff) << 8
        else x = x << 2; y = y << 2 end
        if tot_w <= 1 then x = x - 0x80 end
        if tot_h <= 1 then y = y - 0x80 end
        if integer_pos then
          x, y = x >> 8, y >> 8
          if flipx and zx ~= 0x100 then x = x + tw - tot_w end
          if flipy and zy ~= 0x100 then y = y + th - tot_h end
        else
          if flipx and zx ~= 0x100 then x = x + (tw << 8) - tot_wf - 0x80 end
          if flipy and zy ~= 0x100 then y = y + (th << 8) - tot_hf - 0x80 end
          x, y = x >> 8, y >> 8
        end
        x, y = sext10(x), sext10(y)
      end
      if not (x + tot_w <= 0 or x >= MAX_X or y + tot_h <= 0 or y >= MAX_Y) then
        if ALT and not over then
          clk = clk + tw * th            -- on screen ones only
          if clk > MAX_CLK then over = true; cut = 1024 - i end
        end
        if over then
          lost = lost + 1
          lost_tiles = lost_tiles + cols * rows
        else
          visible = visible + 1
          tiles_vis = tiles_vis + cols * rows
          local pxx, bx = axis(x, cols, zx, MAX_X)
          local pxy, by = axis(y, rows, zy, MAX_Y)
          tiles_on = tiles_on + bx * by
          px_on = px_on + pxx * pxy
        end
      end
    end
  end
  return { bank, entries, tiles_all, visible, tiles_vis, tiles_on, px_on, clk, cut, lost, lost_tiles }
end

local COLS = { "bank", "entries", "tiles_all", "visible", "tiles_vis", "tiles_on", "px_on", "clk",
               "cut", "lost", "lost_tiles" }
local f = assert(io.open(OUT, "w"))
f:write("frame,src," .. table.concat(COLS, ",") .. "\n")
local rows = {}

local frame, last_notify = 0, 0.0
local at_ack = nil       -- this frame's measurement, taken at the acknowledge

_G.cave_load_irq = space:install_read_tap(0x000064, 0x000067, "cave_load_irq",
  function(offset, data, mask)
    if at_ack or frame < 1 or mask ~= 0xffff then return end
    if mach.time:as_double() + 1e-9 < last_notify + FRAME_S - IRQ_S then return end
    at_ack = measure()
  end)

local function stat(col)
  local v = {}
  for _, r in ipairs(rows) do if r.m[4] > 0 then v[#v + 1] = { r.m[col], r.frame } end end
  if #v == 0 then return nil end
  local maxv, maxf = -1, 0
  for _, p in ipairs(v) do if p[1] > maxv then maxv, maxf = p[1], p[2] end end
  table.sort(v, function(a, b) return a[1] < b[1] end)
  return v[(#v + 1) // 2][1], v[math.max(1, math.ceil(#v * 0.99))][1], maxv, maxf, #v
end

local function summary()
  local lines = { string.format("%s: %d frames, %d bpp sprites (%d bytes a 16 x 16 block), list from %s",
                  romname, frame, BPP, BPP * 32, ALT and "the no-zoom format" or "the zoom format") }
  for c = 2, 11 do
    local med, p99, max, maxf, n = stat(c)
    if med then
      lines[#lines + 1] = string.format("  %-10s median %7d  p99 %7d  max %7d (frame %d)", COLS[c], med, p99, max, maxf)
      if c == 3 or c == 5 or c == 6 or c == 11 then
        lines[#lines + 1] = string.format("  %-10s median %7d  p99 %7d  max %7d bytes of sprite ROM", "", med * BPP * 32, p99 * BPP * 32, max * BPP * 32)
      end
    end
  end
  local cuts, losses, n = 0, 0, 0
  for _, r in ipairs(rows) do
    if r.m[4] > 0 then n = n + 1 end
    if r.m[9] > 0 then cuts = cuts + 1 end
    if r.m[10] > 0 then losses = losses + 1 end
  end
  lines[#lines + 1] = string.format("  frames with sprites on screen %d; list cut by MAME's budget in %d, "
                                    .. "on-screen entries lost to it in %d", n, cuts, losses)
  local txt = table.concat(lines, "\n") .. "\n"
  print(txt)
  local s = assert(io.open(OUT:gsub("%.csv$", "") .. ".txt", "w")); s:write(txt); s:close()
end

_G.cave_load_frame = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame >= 2 then                     -- the first draw is in frame 2
    local m, src = at_ack, "a"
    if not m then m, src = measure(), "n" end
    rows[#rows + 1] = { frame = frame, m = m }
    f:write(string.format("%d,%s,%s\n", frame, src, table.concat(m, ",")))
  end
  at_ack = nil
  last_notify = mach.time:as_double()
  if frame >= FRAMES then
    f:close()
    summary()
    mach:exit()
  end
end)
