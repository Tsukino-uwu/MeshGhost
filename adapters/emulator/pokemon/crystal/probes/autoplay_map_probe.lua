-- MeshGhost — Pokémon Crystal: the map around the player, the characters on it and its event lists, for
-- autoplay's crystal.lua (DEV TOOL, READ-ONLY, never shipped) -- 2026-09-17
--
-- READ-ONLY. Writes nothing, presses nothing. Load it beside the autoplay driver and drive with the driver's
-- tools; read each dump against a capture taken on the same tile.
--
-- WHY. autoplay needs `local_map` (what stands on each tile around the player) and `nearby` (the other
-- characters). cmd_drive.lua measured on one map (2026-09-16) that a tile's collision is quadrant
-- (y%2)*2+(x%2) of block (x//2, y//2), found at (by+3)*(wMapWidth+6)+(bx+3) in wOverworldMapBlocks, through the
-- loaded tileset's collision table -- and left open whether that holds on other maps. Our V1.0 build's .sym says
-- where the object records (wObjectStructs, 13 x 0x28; wMapObjects, 16 x 0x10) and the map's event lists
-- (coord, bg, object) are; what their bytes mean is this log's job.
--
-- WHAT IT LOGS, whenever the map, the player's tile or the object records change (at most once per 8 frames
-- while they keep changing), with the frame:
--   * `map` -- group.number, wMapWidth/Height (blocks), wMapBorderBlock, the tileset header's collision
--     bank and pointer, the player's tile;
--   * `grid` -- 11 rows of 15 tiles centred on the player: block id and collision byte per tile (bb:cc);
--   * `obj N` -- every object record whose first byte is not 0, all 0x28 bytes;
--   * `mapobj N` -- every map-object record whose first two bytes are not both 0, all 0x10 bytes;
--   * `events` -- the coord, bg and object event counts and pointers (bank wMapScriptsBank), and each list's
--     first 16 entries raw (8, 5 and 13 bytes a row, the sizes read from what repeats).
-- What it cannot see: collision on tiles outside the block buffer; anything between frames.
--
-- COST. A few hundred reads per logged change, none on a quiet frame beyond a 13-record compare. Log:
-- crystal/logs/autoplay_map_<port>_<timestamp>.log, flushed every 120 frames.

local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local function u8(a) return memory.read_u8(a, "WRAM") end
local function rom8(bank, ptr) return memory.read_u8(bank * 0x4000 + (ptr - 0x4000), "ROM") end

local W_MAPGROUP, W_MAPNUMBER, W_YCOORD, W_XCOORD = flat(0xDCB5), flat(0xDCB6), flat(0xDCB7), flat(0xDCB8)
local W_MAPHEIGHT, W_MAPWIDTH, W_BORDER = flat(0xD19E), flat(0xD19F), flat(0xD19D)
local W_BLOCKS, W_TILESET = flat(0xC800), flat(0xD1D9)
local W_OBJECTS, OBJ_SIZE, OBJ_COUNT = flat(0xD4D6), 0x28, 13
local W_MAPOBJECTS, MAPOBJ_SIZE, MAPOBJ_COUNT = flat(0xD71E), 0x10, 16
local W_SCRIPTS_BANK = flat(0xD1A3)
local EVENT_LISTS = {
	{ name = "coord", count = flat(0xDBFE), ptr = flat(0xDBFF), size = 8 },
	{ name = "bg", count = flat(0xDC01), ptr = flat(0xDC02), size = 5 },
	{ name = "object", count = flat(0xDC04), ptr = flat(0xDC05), size = 13 },
}

local dir, port = ".", tostring(AUTOPLAY_PORT or os.getenv("AUTOPLAY_PORT") or "na")
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logdir = (dir:match("^(.*)/probes$") or dir) .. "/logs"
local logf = io.open(string.format("%s/autoplay_map_%s_%s.log", logdir, port, os.date("%Y%m%d_%H%M%S")), "w")
if logf then logf:setvbuf("full", 65536) end
local function log(s)
	if logf then logf:write(string.format("[%s f%d] %s\n", os.date("%H:%M:%S"), emu.framecount(), s)) end
end

local function hex(bytes)
	local out = {}
	for i = 1, #bytes do out[i] = string.format("%02X", bytes[i]) end
	return table.concat(out, " ")
end

local function collisionOf(block, quadrant)
	local bank, ptr = u8(W_TILESET + 6), u8(W_TILESET + 7) | (u8(W_TILESET + 8) << 8)
	if ptr >= 0x4000 and ptr <= 0x7FFF then return rom8(bank, ptr + block * 4 + quadrant) end
	return nil
end

local function dump()
	local w, h = u8(W_MAPWIDTH), u8(W_MAPHEIGHT)
	local px, py = u8(W_XCOORD), u8(W_YCOORD)
	log(string.format("map %d.%d size %dx%d blocks border %02X tileset %02X coll %02X:%02X%02X player %d,%d",
		u8(W_MAPGROUP), u8(W_MAPNUMBER), w, h, u8(W_BORDER), u8(W_TILESET), u8(W_TILESET + 6), u8(W_TILESET + 8),
		u8(W_TILESET + 7), px, py))
	for dy = -5, 5 do
		local row = {}
		for dx = -7, 7 do
			local x, y = px + dx, py + dy
			local bx, by = x // 2, y // 2
			local idx = (by + 3) * (w + 6) + (bx + 3)
			if bx < -3 or by < -3 or bx >= w + 3 or by >= h + 3 then
				row[#row + 1] = "--:--"
			else
				local b = u8(W_BLOCKS + idx)
				local c = collisionOf(b, (y % 2) * 2 + (x % 2))
				row[#row + 1] = string.format("%02X:%s", b, c and string.format("%02X", c) or "??")
			end
		end
		log(string.format("grid %+d %s", dy, table.concat(row, " ")))
	end
	for i = 0, OBJ_COUNT - 1 do
		local b = memory.read_bytes_as_array(W_OBJECTS + i * OBJ_SIZE, OBJ_SIZE, "WRAM")
		if b[1] ~= 0 then log(string.format("obj %d %s", i, hex(b))) end
	end
	for i = 0, MAPOBJ_COUNT - 1 do
		local b = memory.read_bytes_as_array(W_MAPOBJECTS + i * MAPOBJ_SIZE, MAPOBJ_SIZE, "WRAM")
		if b[1] ~= 0 or b[2] ~= 0 then log(string.format("mapobj %d %s", i, hex(b))) end
	end
	local bank = u8(W_SCRIPTS_BANK)
	for _, e in ipairs(EVENT_LISTS) do
		local n, ptr = u8(e.count), u8(e.ptr) | (u8(e.ptr + 1) << 8)
		local rows = {}
		if ptr >= 0x4000 and ptr <= 0x7FFF then
			for k = 0, math.min(n, 16) - 1 do
				local r = {}
				for j = 0, e.size - 1 do r[#r + 1] = string.format("%02X", rom8(bank, ptr + k * e.size + j)) end
				rows[#rows + 1] = table.concat(r, " ")
			end
		end
		log(string.format("events %s count %d ptr %02X:%04X | %s", e.name, n, bank, ptr, table.concat(rows, " | ")))
	end
end

local lastKey, lastObjects, cooldown, frames = nil, nil, 0, 0
log("loaded")

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if cooldown > 0 then cooldown = cooldown - 1 end
	local key = string.format("%d.%d %d,%d", u8(W_MAPGROUP), u8(W_MAPNUMBER), u8(W_XCOORD), u8(W_YCOORD))
	local objs = {}
	for i = 0, OBJ_COUNT - 1 do
		local b = memory.read_bytes_as_array(W_OBJECTS + i * OBJ_SIZE + 0x10, 2, "WRAM")
		objs[#objs + 1] = u8(W_OBJECTS + i * OBJ_SIZE) .. ":" .. b[1] .. "," .. b[2]
	end
	local objects = table.concat(objs, " ")
	if (key ~= lastKey or objects ~= lastObjects) and cooldown == 0 then
		dump()
		lastKey, lastObjects, cooldown = key, objects, 8
	end
	if logf and frames % 120 == 0 then logf:flush() end
end

MESHGHOST_DEV_UNLOAD = function()
	log("unloaded")
	if logf then
		logf:flush()
		logf:close()
	end
	logf = nil
end
