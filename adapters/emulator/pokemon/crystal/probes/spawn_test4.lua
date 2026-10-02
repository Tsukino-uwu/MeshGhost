-- Pokémon Crystal: spawn test 4. Builds both halves beside the player, cross-linked the way the engine links what it
-- adopts (the map object's struct id to our struct, the struct's map object index to our map object), since neither
-- adoption path ever looks at a tile beside the player. Success is the engine maintaining OBJECT_SPRITE_X/Y as the
-- camera moves, not a sprite appearing. Writes object RAM only, never a save; vanilla V1.0 only. Open it in the Lua
-- Console beside a clear tile and walk around it.

local DOMAIN = "WRAM"
local ROM_DOMAIN = "ROM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

local OBJECT_STRUCTS = flat(0xD4D6)
local MAP_OBJECTS = flat(0xD71E)
local W_YCOORD, W_XCOORD = flat(0xDCB7), flat(0xDCB8)
local W_MAPGROUP, W_MAPNUMBER = flat(0xDCB5), flat(0xDCB6)
local W_MAPSTATUS = flat(0xD432)
local W_BATTLEMODE = flat(0xD22D)

local OBJECT_LENGTH = 0x28
local MAPOBJECT_LENGTH = 0x10
local NUM_OBJECT_STRUCTS = 13
local NUM_MAP_OBJECTS = 16

-- map_object fields
local M_OBJECT_STRUCT_ID, M_SPRITE, M_Y_COORD, M_X_COORD = 0x00, 0x01, 0x02, 0x03
-- object_struct fields
local F_SPRITE, F_MAP_OBJECT_INDEX = 0x00, 0x01
local F_MAP_X, F_MAP_Y = 0x10, 0x11
local F_LAST_MAP_X, F_LAST_MAP_Y = 0x12, 0x13
local F_INIT_X, F_INIT_Y = 0x14, 0x15
local F_SPRITE_X, F_SPRITE_Y = 0x17, 0x18

local SPAWN_AFTER_FRAMES = 120
local UNASSIGNED = 0xFF
local MAPSTATUS_HANDLE = 2
local MAPSTATUS = { [0] = "START", [1] = "ENTER", [2] = "HANDLE", [3] = "DONE" }

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/spawn_test4_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, never flushed per line: a console line plus a flush stalls the emulator's thread for frames.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- The console gets the first lines and one in twenty; the file gets every line.
local rawConsole, consoleLines = console.log, 0
local function raw_log(msg)
	consoleLines = consoleLines + 1
	if consoleLines <= 4 or consoleLines % 20 == 0 then
		rawConsole(msg)
	end
end
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		-- Flushed every 20 lines: bounded cost, and a live log (an unflushed one reads as nothing happened).
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
	end
end

local function u8(addr, domain)
	local ok, v = pcall(memory.read_u8, addr, domain or DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function w8(addr, value)
	pcall(memory.write_u8, addr, value, DOMAIN)
end

local function rom_is_vanilla_v1()
	local t = {}
	for i = 0, 9 do
		local c = u8(0x134 + i, ROM_DOMAIN)
		if not c then
			return false, "could not read the ROM domain"
		end
		t[#t + 1] = string.char(c)
	end
	if table.concat(t) ~= "PM_CRYSTAL" then
		return false, string.format("ROM title is %q", table.concat(t))
	end
	if u8(0x14E, ROM_DOMAIN) ~= 0x12 or u8(0x14F, ROM_DOMAIN) ~= 0x9F then
		return false, "global checksum is not 129F (vanilla V1.0)"
	end
	return true, "vanilla Crystal V1.0"
end

local function free_map_object()
	for i = 1, NUM_MAP_OBJECTS - 1 do
		if u8(MAP_OBJECTS + (i * MAPOBJECT_LENGTH) + M_SPRITE) == 0 then
			return i
		end
	end
	return nil
end

local function free_struct()
	for i = 1, NUM_OBJECT_STRUCTS - 1 do
		if u8(OBJECT_STRUCTS + (i * OBJECT_LENGTH) + F_SPRITE) == 0 then
			return i
		end
	end
	return nil
end

local function tile_occupied(x, y)
	for i = 0, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + (i * MAPOBJECT_LENGTH)
		if (u8(base + M_SPRITE) or 0) ~= 0
			and u8(base + M_X_COORD) == x and u8(base + M_Y_COORD) == y then
			return true
		end
	end
	return false
end

-- Beside the player, never on top of them, and never on an occupied tile.
local function pick_spot(px, py)
	for _, d in ipairs({ { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 }, { 3, 0 }, { -3, 0 } }) do
		local x, y = px + d[1], py + d[2]
		if x >= 0 and y >= 0 and not tile_occupied(x, y) then
			return x, y
		end
	end
	return nil
end

open_log()
log("=== MeshGhost Crystal spawn test 4 — map object + struct, cross-linked (WRITES RAM) ===")

local ok, why = rom_is_vanilla_v1()
if not ok then
	log("REFUSING TO WRITE: " .. why)
	return
end
log("ROM guard passed: " .. why)

local frames, written = 0, false
local mine, last_key = nil, nil

local function tick()
	frames = frames + 1

	if not written then
		if frames < SPAWN_AFTER_FRAMES then
			return
		end
		-- The in-game gate: the world exists and is stable, and no battle is running.
		if u8(W_MAPSTATUS) ~= MAPSTATUS_HANDLE or u8(W_BATTLEMODE) ~= 0 then
			return
		end

		local mo, st = free_map_object(), free_struct()
		if not mo or not st then
			log("No free map object and/or object struct slot on this map. Not writing.")
			written = true
			return
		end

		local px, py = u8(W_XCOORD) or 0, u8(W_YCOORD) or 0
		local gx, gy = pick_spot(px, py)
		if not gx then
			log("No clear tile beside the player. Move somewhere more open.")
			written = true
			return
		end

		local mo_base = MAP_OBJECTS + (mo * MAPOBJECT_LENGTH)
		local st_base = OBJECT_STRUCTS + (st * OBJECT_LENGTH)

		-- The player's own map object and struct as templates, coordinates fixed and the two pointed at each other.
		for off = 0, MAPOBJECT_LENGTH - 1 do
			w8(mo_base + off, u8(MAP_OBJECTS + off) or 0)
		end
		for off = 0, OBJECT_LENGTH - 1 do
			w8(st_base + off, u8(OBJECT_STRUCTS + off) or 0)
		end

		w8(mo_base + M_X_COORD, gx)
		w8(mo_base + M_Y_COORD, gy)
		w8(mo_base + M_OBJECT_STRUCT_ID, st) -- map object -> our struct

		w8(st_base + F_MAP_OBJECT_INDEX, mo) -- struct -> our map object
		for _, off in ipairs({ F_MAP_X, F_LAST_MAP_X, F_INIT_X }) do
			w8(st_base + off, gx)
		end
		for _, off in ipairs({ F_MAP_Y, F_LAST_MAP_Y, F_INIT_Y }) do
			w8(st_base + off, gy)
		end

		written = true
		mine = {
			mo = mo, st = st, x = gx, y = gy,
			sprite = u8(st_base + F_SPRITE),
			group = u8(W_MAPGROUP), number = u8(W_MAPNUMBER),
			mo_base = mo_base, st_base = st_base,
		}
		log(string.format(
			"Linked map object %d <-> struct %d, at %d,%d (player at %d,%d) on map %s/%s.",
			mo, st, gx, gy, px, py, tostring(mine.group), tostring(mine.number)
		))
		log("LOOK AT THE SCREEN: a character should be beside you.")
		log(">>> Now WALK AROUND IT. <<< Watch whether it holds its tile like an NPC, or slides")
		log("with the screen. The log reports the engine-maintained screen coordinates.")
		return
	end

	if not mine then
		return
	end

	-- OBJECT_SPRITE_X/Y are maintained by the engine for objects it drives; reading back our write proves nothing.
	local gone = u8(W_MAPGROUP) ~= mine.group or u8(W_MAPNUMBER) ~= mine.number
		or u8(mine.st_base + F_SPRITE) ~= mine.sprite
	local sx, sy = u8(mine.st_base + F_SPRITE_X), u8(mine.st_base + F_SPRITE_Y)
	local key = string.format("%s|%s|%s|%s", tostring(gone), tostring(sx), tostring(sy),
		tostring(u8(W_MAPSTATUS)))
	if key == last_key then
		return
	end
	last_key = key

	if gone then
		log(string.format("  f=%-7d ghost GONE (map change or slot reused).", frames))
		return
	end
	log(string.format(
		"  f=%-7d mapStatus=%-6s engine-maintained sprite_x=%s sprite_y=%s  (changing = the game owns it)",
		frames, MAPSTATUS[u8(W_MAPSTATUS)] or "?", tostring(sx), tostring(sy)
	))
end

event.onexit(function()
	pcall(function()
		if not mine then
			return
		end
		w8(mine.st_base + F_SPRITE, 0)
		for off = 0, MAPOBJECT_LENGTH - 1 do
			w8(mine.mo_base + off, 0)
		end
	end)
end)

while true do
	tick()
	emu.frameadvance()
end
