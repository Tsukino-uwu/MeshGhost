-- objtiles_probe.lua -- READ-ONLY: who owns OBJ VRAM's tiles right now?
--
-- Question (2026-09-02): after a warp, the Emerald adapter's spawn and hardware tiers both report
-- "no run of free OBJ tiles" for a 16-tile body, so the engine's own sprite-tile allocation bitmap
-- must be full -- of what? This counts the bitmap's set bits every second and, for every in-use
-- entry of gSprites, the tile number it points at, so "bits set" can be compared with "tiles a
-- live sprite actually uses". A large gap is orphaned bits: allocated by someone and never freed.
--
-- Addresses are the adapter's own (adapters/emulator/pokemon/emerald/meshghost_emerald.lua):
--   sSpriteTileAllocBitmap 0x02021b3c (line 2618), gReservedSpriteTileCount 0x02021b3a (2619),
--   TOTAL_OBJ_TILE_COUNT 1024 (2621), gSprites 0x02020630 (86), SPRITE_SIZE 0x44 (87),
--   MAX_SPRITES 64 (2610); sprite inUse = bit 0 of +0x3e (line 3972), tileNum = attr2 & 0x3ff at
--   +0x04 (line 6158). Reads only. Loader contract; one buffered line a second to objtiles.log.
local dir = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or ".")
local f = io.open(dir .. "/objtiles.log", "a")
local frames = 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if frames % 60 ~= 0 then return end
	local set = 0
	for n = 0, 1023 do
		if (memory.read_u8(0x02021b3c + (n // 8)) >> (n % 8)) & 1 == 1 then set = set + 1 end
	end
	local inUse, owned = 0, {}
	local parts = {}
	for i = 0, 63 do
		local d = 0x02020630 + i * 0x44
		if (memory.read_u8(d + 0x3e) & 1) == 1 then
			inUse = inUse + 1
			local t = memory.read_u16_le(d + 0x04) & 0x3ff
			owned[#owned + 1] = t
			parts[#parts + 1] = string.format("%d@%d", i, t)
		end
	end
	table.sort(owned)
	f:write(string.format("%s reserved=%d bitsSet=%d/1024 spritesInUse=%d tileNums=[%s]\n",
		os.date("%H:%M:%S"), memory.read_u16_le(0x02021b3a), set, inUse, table.concat(parts, " ")))
	f:flush()
end
MESHGHOST_DEV_UNLOAD = function() if f then f:close() end end
