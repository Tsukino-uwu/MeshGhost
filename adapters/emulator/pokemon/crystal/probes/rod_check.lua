-- Pokémon Crystal: is the rod the drawn tier reads from the cartridge the rod the engine drew? Read-only, one shot:
-- on the first frame the local player holds a fishing facing, it prints the two tiles at the ROM rod address and
-- VRAM tiles $fc/$fd in both banks as pixels, plus the OAM entries drawing them. A match means the read is right.

local OUT = MESHGHOST_FISH_DIR
if not OUT then
  local info = debug.getinfo(1, "S")
  OUT = "."
  if info and info.source and info.source:sub(1, 1) == "@" then
    local src = info.source:sub(2):gsub("\\", "/")
    OUT = src:match("^(.*)/[^/]*$") or "."
  end
end

local function flat(cpu)
  if cpu < 0xD000 then return cpu - 0xC000 end
  return 0x1000 + (cpu - 0xD000)
end
local ST = flat(0xD4D6)
local F_ACTION, F_FACING, F_DIRECTION = 0x0B, 0x0D, 0x08
local ROD_ROM = 0x104560 -- FishingRodGFX, 41:4560 (adapter's own vanilla table)
local VRAM_BANK0, VRAM_BANK1 = 0x0000, 0x2000

local logfile = io.open(OUT .. "/rod_check.log", "w")
local function log(m)
  console.log(m)
  if logfile then logfile:write(m, "\n") pcall(function() logfile:flush() end) end
end

local GLYPH = { [0] = ".", "1", "2", "3" }
local function dump(label, readByte, base)
  log(label)
  for row = 0, 7 do
    local lo, hi = readByte(base + row * 2) or 0, readByte(base + row * 2 + 1) or 0
    local line = {}
    for bit = 0, 7 do
      local mask = 1 << (7 - bit)
      local idx = ((lo & mask) ~= 0 and 1 or 0) | (((hi & mask) ~= 0 and 1 or 0) << 1)
      line[#line + 1] = GLYPH[idx]
    end
    log("    " .. table.concat(line))
  end
end

local function romByte(a) return memory.read_u8(a, "ROM") end
local function vramByte(a) return memory.read_u8(a, "VRAM") end

local fired = false
local function tick()
  if fired then return end
  local face = memory.read_u8(ST + F_FACING, "WRAM") or 0
  if face < 0x10 or face > 0x13 then return end
  fired = true

  log(string.format("=== rod_check === frame %d, player action=%02X facing=%02X direction=%02X",
    emu.framecount(), memory.read_u8(ST + F_ACTION, "WRAM") or 0, face,
    memory.read_u8(ST + F_DIRECTION, "WRAM") or 0))
  log("The engine is drawing the player's rod RIGHT NOW, so its own copy is resident.")

  dump("  ROM tile 0 (what a DOWN/UP ghost rod is painted from):", romByte, ROD_ROM)
  dump("  ROM tile 1 (what a LEFT/RIGHT ghost rod is painted from):", romByte, ROD_ROM + 16)
  dump("  VRAM bank 0 tile $fc:", vramByte, VRAM_BANK0 + 0xFC * 16)
  dump("  VRAM bank 0 tile $fd:", vramByte, VRAM_BANK0 + 0xFD * 16)
  dump("  VRAM bank 1 tile $fc:", vramByte, VRAM_BANK1 + 0xFC * 16)
  dump("  VRAM bank 1 tile $fd:", vramByte, VRAM_BANK1 + 0xFD * 16)

  -- The OAM the engine emitted, so the rod's offset from the body is measured rather than read off a table; the
  -- hardware's +16/+8 bias cancels in the differences.
  log("  OAM entries with a tile of $fc or $fd, and the player's own four, as y,x,tile,attr:")
  for e = 0, 39 do
    local y = memory.read_u8(e * 4, "OAM") or 0
    local x = memory.read_u8(e * 4 + 1, "OAM") or 0
    local t = memory.read_u8(e * 4 + 2, "OAM") or 0
    local a = memory.read_u8(e * 4 + 3, "OAM") or 0
    if y ~= 0 and y < 176 then
      log(string.format("    oam %2d: y=%3d x=%3d tile=%02X attr=%02X%s", e, y, x, t, a,
        (t == 0xFC or t == 0xFD) and "   <-- ROD" or ""))
    end
  end
  log("rod_check: done, one shot. Remove it from the loader when you have read this.")
end

MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function() if logfile then pcall(function() logfile:close() end) end end
if not MESHGHOST_DEV_LOADER then
  while true do tick() emu.frameadvance() end
end
