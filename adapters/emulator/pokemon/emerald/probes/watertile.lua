-- MeshGhost — Pokémon Emerald: put water in front of the player (dev tool, writes the live map grid, never shipped).
-- Load it in the overworld: after a countdown the tile being faced becomes water; unloading or a map load undoes it.

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

-- Only this map's own tilesets: a metatile id from another tileset would draw as unrelated garbage.
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
	-- Collision 0 at elevation 1, never the collision bit: water is another elevation; a solid tile refuses the rod.
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
