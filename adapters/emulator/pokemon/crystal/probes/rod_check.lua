-- MeshGhost — Pokémon Crystal: is the rod we read from the cartridge the rod the engine drew?
--
-- DEVELOPMENT TOOL, read-only. It presses nothing and writes nothing.
--
-- WHY THIS EXISTS
-- The drawn tier paints a peer's fishing rod from ROM (`FISHING_ROD_ROM`), because on a receiving
-- machine the two VRAM tiles it would otherwise share hold the jump shadow instead. That read is
-- the one thing in the fishing path with no in-game check behind it — so when the user reported
-- the ghosts' rods looking *"sideways/weird"* while the player's looked right, the first question
-- is whether the bytes we decode are the bytes the engine has.
--
-- WHAT IT DOES
-- While the LOCAL player is fishing (the one moment the engine's own copy of the rod is resident),
-- it prints, as pixels:
--   * the two tiles at FISHING_ROD_ROM, decoded exactly the way the adapter decodes them;
--   * VRAM tiles $fc and $fd in BOTH banks, decoded the same way.
-- If the ROM pair and one VRAM pair are identical, the cartridge read is right and the fault is in
-- placement. If they differ, the read is wrong and everything drawn from it is arbitrary.
-- `probes.md`: diff what you BUILT against what the game BUILT.
--
-- It fires ONCE, on the first frame it sees the player holding a FISH facing, and then goes quiet.

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

  -- The OAM the engine actually emitted for the player, so the rod's REAL offset from the body is
  -- a measurement rather than a reading of the facing table. Entries are y, x, tile, attributes;
  -- the GB's OAM y/x carry the hardware's own +16/+8 bias, which cancels in the differences below.
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
