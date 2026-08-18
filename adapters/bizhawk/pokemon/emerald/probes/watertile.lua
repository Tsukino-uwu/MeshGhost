-- MeshGhost — Pokémon Emerald: put water in front of the player (DEV TOOL, never shipped)
--
-- WHY
-- Testing a surfing or fishing ghost needs water, and the water is somewhere else. Walking there
-- costs the user's time; warping needs machinery we do not have. But the game decides what a tile
-- IS from one number, so the cheaper move is to change the tile: find a metatile in the tilesets
-- this map already has loaded whose behaviour is water, and write it into the ground in front of
-- the player. The game then treats it as water, because as far as it is concerned it is.
--
-- This is the "combine the tools" idea in one script (agent_docs/environment.md): read the
-- decompilation to learn what makes a tile water, write memory to make one, checkpoint with a
-- savestate so the change is free to undo, and drive input to use it.
--
-- CHEAT, DEV ONLY, AND REVERSIBLE. It edits the live map grid, not the save -- the map is rebuilt
-- from ROM on the next map load, so walking out and back in undoes it. It restores the original
-- tile itself on unload as well. Nothing here is ever part of an adapter.
--
-- ADDRESSES, from our own make-compare-verified pokeemerald build:
--   gBackupMapLayout 03005DC0  { s32 width 0x00, s32 height 0x04, u16 *map 0x08 }
--   gMapHeader       02037318  -> mapLayout 0x00 -> primaryTileset 0x10, secondaryTileset 0x14
--   struct Tileset: metatileAttributes at 0x10
--   MAPGRID_METATILE_ID_MASK 0x03FF, METATILE_ATTR_BEHAVIOR_MASK 0x00FF
--   NUM_METATILES_IN_PRIMARY 512; MB_POND_WATER 16, MB_OCEAN_WATER 21
--
-- HOW TO RUN
--   Point dev-scripts/bizhawk-dev-loader.target at this file while standing in the overworld.
--   It counts down, then converts the tile you are FACING into water and reports what it used.

local GBACKUPMAPLAYOUT = 0x03005dc0
local GMAPHEADER = 0x02037318
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local NUM_METATILES_IN_PRIMARY = 512
local MAPGRID_METATILE_ID_MASK = 0x03ff
local METATILE_ATTR_BEHAVIOR_MASK = 0x00ff
local MAPGRID_COLLISION_MASK = 0x0c00
local MAPGRID_ELEVATION_MASK = 0xf000
local ELEVATION_SURF = 1 -- water; the player walks at ELEVATION_DEFAULT (3)
local WATER_BEHAVIOURS = { [16] = "MB_POND_WATER", [21] = "MB_OCEAN_WATER", [18] = "MB_DEEP_WATER" }

local logfile
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/watertile_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end
local function log(m)
	console.log(m)
	if logfile then logfile:write(m, "\n") logfile:flush() end
end

local function u8(a) return memory.read_u8(a) end
local function u16(a) return memory.read_u16_le(a) end
local function s16(a) return memory.read_s16_le(a) end
local function u32(a) return memory.read_u32_le(a) end
local function s32(a) return memory.read_s32_le(a) end

-- Which tileset owns a metatile id, and where its attribute table is.
local function behaviourOf(metatileId)
	local layout = u32(GMAPHEADER + 0x00)
	if layout == 0 then return nil end
	local tileset, index
	if metatileId < NUM_METATILES_IN_PRIMARY then
		tileset, index = u32(layout + 0x10), metatileId
	else
		tileset, index = u32(layout + 0x14), metatileId - NUM_METATILES_IN_PRIMARY
	end
	if tileset == 0 then return nil end
	local attrs = u32(tileset + 0x10)
	if attrs == 0 then return nil end
	return u16(attrs + index * 2) & METATILE_ATTR_BEHAVIOR_MASK
end

-- The first metatile in this map's own tilesets that the game considers water. Searching what is
-- already loaded matters: a metatile id from another tileset would render as unrelated garbage.
local function findWaterMetatile()
	for id = 0, 1023 do
		local b = behaviourOf(id)
		if b and WATER_BEHAVIOURS[b] then return id, b end
	end
	return nil
end

local DIR_DELTA = { [1] = { 0, 1 }, [2] = { 0, -1 }, [3] = { -1, 0 }, [4] = { 1, 0 } }

local function tileInFront()
	local objId = u8(GPLAYERAVATAR_ADDR + 0x05)
	local a = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
	local dir = u8(a + 0x18) & 0x0f
	local d = DIR_DELTA[dir] or DIR_DELTA[1]
	return s16(a + 0x10) + d[1], s16(a + 0x12) + d[2], dir
end

local function gridAddr(x, y)
	local width = s32(GBACKUPMAPLAYOUT + 0x00)
	local map = u32(GBACKUPMAPLAYOUT + 0x08)
	if map == 0 or width <= 0 then return nil end
	return map + (x + width * y) * 2
end

local original = nil

local COUNTDOWN = 240
local frames, done = 0, false

MESHGHOST_DEV_TICK = function()
	if done then return end
	frames = frames + 1
	if frames % 60 == 0 and frames < COUNTDOWN then
		log(string.format("placing water in %d...", (COUNTDOWN - frames) // 60))
	end
	if frames < COUNTDOWN then return end
	done = true

	local waterId, behaviour = findWaterMetatile()
	if not waterId then
		log("no water metatile in this map's tilesets -- try a map that has some water on it.")
		return
	end
	local x, y, dir = tileInFront()
	local addr = gridAddr(x, y)
	if not addr then
		log("could not reach the map grid.")
		return
	end
	original = { addr = addr, value = u16(addr) }
	-- Metatile id, collision ZERO, and elevation ELEVATION_SURF. Two wrong versions came first and
	-- the second is the instructive one:
	--   v1 changed only the metatile id, so the tile had water behaviour but stayed walkable.
	--   v2 then set the COLLISION bit, which made it solid -- and a "walk into it" test was
	--      blocked, which looked like success and was not. Real water is not impassable; it is a
	--      different ELEVATION. `IsPlayerFacingSurfableFishableWater` (field_player_avatar.c:1322)
	--      requires GetCollisionAtCoords to return COLLISION_ELEVATION_MISMATCH, which an
	--      impassable tile never produces -- so the "fix" that made the symptom look right was
	--      precisely what stopped fishing from working.
	-- Water is elevation 1 (ELEVATION_SURF) against the player's 3 (ELEVATION_DEFAULT), and that
	-- mismatch is what the game reads as "you are standing next to water".
	local kept = u16(addr) & ~(MAPGRID_METATILE_ID_MASK | MAPGRID_COLLISION_MASK | MAPGRID_ELEVATION_MASK)
	memory.write_u16_le(addr, kept | (waterId & MAPGRID_METATILE_ID_MASK) | (ELEVATION_SURF << 12))
	log(string.format("tile in front (%d,%d, facing %d) -> metatile %d (%s); was 0x%04X",
		x, y, dir, waterId, WATER_BEHAVIOURS[behaviour], original.value))
	log("Face it and try to Surf or fish. The map is rebuilt from ROM on the next map load,")
	log("so leaving and returning undoes this even if the restore below does not run.")
end

MESHGHOST_DEV_UNLOAD = function()
	if original then
		pcall(function() memory.write_u16_le(original.addr, original.value) end)
	end
	if logfile then logfile:close() logfile = nil end
end
