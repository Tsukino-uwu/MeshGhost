-- Pokémon Crystal: spawn test 3. Writes a map object on the row CheckObjectEnteringVisibleRange scans (just below
-- the screen while walking down), to ask whether our bytes are acceptable to the engine's own adoption path: that
-- routine adopts only objects on the row about to scroll into view, and only mid-step. Writes object RAM only, never
-- a save; vanilla V1.0 only. Open it in the Lua Console in the overworld and walk down several steps.

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
local W_YCOORD = flat(0xDCB7)
local W_XCOORD = flat(0xDCB8)
local W_MAPSTATUS = flat(0xD432)

local OBJECT_LENGTH = 0x28
local MAPOBJECT_LENGTH = 0x10
local NUM_OBJECT_STRUCTS = 13
local NUM_MAP_OBJECTS = 16

local M_OBJECT_STRUCT_ID = 0x00
local M_SPRITE = 0x01
local M_Y_COORD = 0x02
local M_X_COORD = 0x03

-- The row CheckObjectEnteringVisibleRange scans when walking down.
local BELOW_SCREEN_DY = 9

local SPAWN_AFTER_FRAMES = 120
local UNASSIGNED = 0xFF
local MAPSTATUS_HANDLE = 2

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/spawn_test3_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
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

local function find_free_map_object()
	for i = 1, NUM_MAP_OBJECTS - 1 do
		if u8(MAP_OBJECTS + (i * MAPOBJECT_LENGTH) + M_SPRITE) == 0 then
			return i
		end
	end
	return nil
end

-- A free slot is not a free tile: wYCoord+9 can be exactly where an NPC stands.
local function tile_occupied(x, y)
	for i = 0, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + (i * MAPOBJECT_LENGTH)
		if (u8(base + M_SPRITE) or 0) ~= 0 then
			if u8(base + M_X_COORD) == x and u8(base + M_Y_COORD) == y then
				return true
			end
		end
	end
	return false
end

-- Pick a spot on the row the engine scans, stepping sideways until the tile is actually empty.
local function pick_x(px, y)
	for _, dx in ipairs({ 0, 1, -1, 2, -2, 3, -3 }) do
		local x = px + dx
		if x >= 0 and not tile_occupied(x, y) then
			return x
		end
	end
	return nil
end

local function dump_map_objects(label)
	log(label)
	for i = 0, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + (i * MAPOBJECT_LENGTH)
		local sprite = u8(base + M_SPRITE) or 0
		if sprite ~= 0 then
			log(string.format(
				"  %2d: sprite=%3d structId=%3d at %d,%d",
				i, sprite, u8(base + M_OBJECT_STRUCT_ID) or -1,
				u8(base + M_X_COORD) or -1, u8(base + M_Y_COORD) or -1
			))
		end
	end
end

open_log()
log("=== MeshGhost Crystal spawn test 3 — placed on the row the engine scans (WRITES RAM) ===")

local ok, why = rom_is_vanilla_v1()
if not ok then
	log("REFUSING TO WRITE: " .. why)
	return
end
log("ROM guard passed: " .. why)

local src = MAP_OBJECTS -- the player's map object, index 0, as a known-good template
local DST, dst
local frames, written, written_at = 0, false, 0
local adopted = false
local last_state = nil

-- What we wrote, so our object is told apart from a different map's NPC that inherits the slot (which also clears
-- the -1 struct id).
local mine = nil -- { sprite, x, y, group, number }
local W_MAPGROUP = flat(0xDCB5)
local W_MAPNUMBER = flat(0xDCB6)

local function map_changed()
	return u8(W_MAPGROUP) ~= mine.group or u8(W_MAPNUMBER) ~= mine.number
end

-- Our object is still ours only if the map has not changed and the slot still holds what we put there, coordinates
-- included, since a slot can be reused within the same map.
local function still_ours()
	if map_changed() then
		return false
	end
	return u8(dst + M_SPRITE) == mine.sprite
		and u8(dst + M_X_COORD) == mine.x
		and u8(dst + M_Y_COORD) == mine.y
end

local MAPSTATUS = { [0] = "START", [1] = "ENTER", [2] = "HANDLE", [3] = "DONE" }

local function tick()
	frames = frames + 1

	if not written then
		if frames < SPAWN_AFTER_FRAMES then
			return
		end
		if u8(W_MAPSTATUS) ~= MAPSTATUS_HANDLE then
			return -- the in-game gate: the world must exist and be stable before writing
		end

		dump_map_objects("Map objects before writing:")

		DST = find_free_map_object()
		if not DST then
			log("No free map object slot on this map. Not writing.")
			written = true
			return
		end
		dst = MAP_OBJECTS + (DST * MAPOBJECT_LENGTH)

		for off = 0, MAPOBJECT_LENGTH - 1 do
			w8(dst + off, u8(src + off) or 0)
		end

		-- Coordinates from wXCoord/wYCoord, the space CheckObjectEnteringVisibleRange compares against, not the
		-- player's map object, whose coords are its spawn position.
		local px, py = u8(W_XCOORD) or 0, u8(W_YCOORD) or 0
		local gy = py + BELOW_SCREEN_DY
		local gx = pick_x(px, gy)
		if not gx then
			log("Every candidate tile on the scan row is occupied. Not writing — move elsewhere.")
			written = true
			return
		end
		w8(dst + M_X_COORD, gx)
		w8(dst + M_Y_COORD, gy)
		w8(dst + M_OBJECT_STRUCT_ID, UNASSIGNED)

		written = true
		written_at = frames
		mine = {
			sprite = u8(dst + M_SPRITE),
			x = gx,
			y = gy,
			group = u8(W_MAPGROUP),
			number = u8(W_MAPNUMBER),
		}
		log(string.format(
			"Wrote map object %d: sprite=%s at %d,%d on map %s/%s (player is at %d,%d).",
			DST, tostring(mine.sprite), gx, gy,
			tostring(mine.group), tostring(mine.number), px, py
		))
		log(">>> WALK DOWN. <<< The engine scans the row at wYCoord+9 as it scrolls into view,")
		log("and only while a step is in progress. Beside the player it would never be seen.")
		return
	end

	-- After adoption, watch our object itself: an unchanged struct count is not unchanged contents.
	if adopted then
		local status = u8(W_MAPSTATUS)
		local ours = still_ours()
		local id = u8(dst + M_OBJECT_STRUCT_ID)
		local key = string.format("%s|%s|%s", tostring(ours), tostring(id), tostring(status))
		if key ~= last_state then
			last_state = key
			local what
			if map_changed() then
				what = string.format(
					"GONE — map changed to %s/%s, our object did not survive it",
					tostring(u8(W_MAPGROUP)), tostring(u8(W_MAPNUMBER))
				)
			elseif not ours then
				what = "GONE — the slot no longer holds our object (wiped or reused)"
			elseif id == UNASSIGNED then
				what = "still present, but UNADOPTED again (lost its struct)"
			else
				what = string.format("alive, struct %d", id)
			end
			log(string.format(
				"  f=%-7d mapStatus=%-6s ghost: %s",
				frames, MAPSTATUS[status] or tostring(status), what
			))
		end
		return
	end

	-- Adoption counts only if the slot still holds our object.
	if map_changed() then
		log(string.format(
			"Map changed to %s/%s before adoption — our object is gone. Nothing more to watch.",
			tostring(u8(W_MAPGROUP)), tostring(u8(W_MAPNUMBER))
		))
		adopted = true -- stop the pre-adoption path; the watcher above reports honestly from here
		return
	end

	local id = u8(dst + M_OBJECT_STRUCT_ID)
	if id and id ~= UNASSIGNED and still_ours() then
		adopted = true
		log(string.format("*** ADOPTED at +%d frames: engine assigned object struct %d ***",
			frames - written_at, id))
		log(string.format("Verified still ours: sprite=%s at %d,%d on the same map.",
			tostring(mine.sprite), mine.x, mine.y))
		dump_map_objects("Map objects after adoption:")
		log("LOOK AT THE SCREEN: a character should be there, and it should behave like an NPC.")
		return
	end

	local n = frames - written_at
	if n % 300 == 0 then
		log(string.format(
			"  +%d frames: still unadopted. player now at %d,%d, ghost row is %d.",
			n, u8(W_XCOORD) or -1, u8(W_YCOORD) or -1, u8(dst + M_Y_COORD) or -1
		))
	end
end

event.onexit(function()
	pcall(function()
		if not dst then
			return
		end
		local id = u8(dst + M_OBJECT_STRUCT_ID)
		if id and id ~= UNASSIGNED and id < NUM_OBJECT_STRUCTS then
			w8(OBJECT_STRUCTS + (id * OBJECT_LENGTH), 0)
		end
		for off = 0, MAPOBJECT_LENGTH - 1 do
			w8(dst + off, 0)
		end
	end)
end)

while true do
	tick()
	emu.frameadvance()
end
