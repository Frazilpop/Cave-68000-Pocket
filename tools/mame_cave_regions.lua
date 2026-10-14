-- SPDX-License-Identifier: GPL-3.0-or-later
-- Cave 68000 (Pocket): dump MAME's ROM regions for a set of this board, so
-- tools/pocket/verify_rom.py can check the .rom image byte for byte.
--
--   DUMP_DIR=build/mame/regions/ddonpach \
--   mame -rompath ~/Downloads ddonpach -autoboot_script tools/mame_cave_regions.lua \
--        -skip_gameinfo -autoboot_delay 0 -video none -sound none -nothrottle
--
-- (verify_rom.py runs this for you.) Writes <region>.bin for maincpu,
-- sprites0, layer0, layer1, layer2, ymz (DonPachi: oki1 and oki2) and eeprom
-- – the ones the set has –
-- each at MAME's region size, plus regions.txt listing size / endianness /
-- width.
--
-- LOGICAL BYTE ORDER. maincpu is a 16-bit big-endian region and MAME stores
-- it byte-swapped on a little-endian host; memory_region:read_u8/read_u32 undo
-- that (luaengine_mem.cpp region_read applies BYTE8_XOR_BE), so byte 0 here is
-- the high byte of the 68000's first word — the order of the .rom image. The
-- graphics regions are 8-bit and come out as ROM_LOAD left them: sprites0 on
-- ddonpach word-swapped (ROM_LOAD16_WORD_SWAP), on esprade and guwange as
-- ROM_LOAD32_WORD_SWAP interleaves the pairs; verify_rom.py maps the image's
-- order onto those.

local DIR  = os.getenv("DUMP_DIR") or "."
local mach = manager.machine
local NAMES = { "maincpu", "sprites0", "layer0", "layer1", "layer2", "ymz", "oki1", "oki2", "eeprom" }

local function dump(name)
  local r = mach.memory.regions[":" .. name]
  if not r then print("  no region :" .. name); return nil end
  local f = assert(io.open(DIR .. "/" .. name .. ".bin", "wb"))
  -- read_u32 in the region's own endianness gives the next four LOGICAL bytes
  -- as a number; pack it back the same way round.
  local fmt = (r.endianness == "big") and ">I4" or "<I4"
  local size = r.size
  local chunk = {}
  local a = 0
  while a + 4 <= size do
    chunk[#chunk + 1] = string.pack(fmt, r:read_u32(a))
    a = a + 4
    if #chunk >= 8192 then f:write(table.concat(chunk)); chunk = {} end
  end
  while a < size do chunk[#chunk + 1] = string.char(r:read_u8(a)); a = a + 1 end
  f:write(table.concat(chunk))
  f:close()
  print(string.format("  %-8s %8x bytes  %s %d-bit", name, size, r.endianness, r.bitwidth))
  return string.format("%s size=%d endianness=%s bitwidth=%d\n", name, size, r.endianness, r.bitwidth)
end

local meta = assert(io.open(DIR .. "/regions.txt", "w"))
meta:write("set=" .. emu.romname() .. "\n")
for _, n in ipairs(NAMES) do
  local line = dump(n)
  if line then meta:write(line) end
end
meta:close()
mach:exit()
