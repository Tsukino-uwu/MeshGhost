-- Writes object RAM (vanilla V1.0 only, never a save): writes a map object, a copy of the player's two tiles right
-- with its struct id left at -1, and waits for the engine to adopt it. Success is the engine replacing the -1 with
-- a real slot, a value we did not write; then walk and watch whether sprite and collision stay together. Stop any
-- other MeshGhost script first; the write is undone on exit.

local DOMAIN = "WRAM"
local ROM_DOMAIN = "ROM"

local function flat(cpu_addr)
	return 0x1000 + (cpu_addr - 0xD000)
end

local OBJECT_STRUCTS = flat(0xD4D6) -- 01:d4d6
local MAP_OBJECTS = flat(0xD71E) -- 01:d71e, object 0 is the player
local OBJECT_LENGTH = 0x28
local MAPOBJECT_LENGTH = 0x10
local NUM_OBJECT_STRUCTS = 13

-- Map-object fields, from the decompilation's layout.
local M_OBJECT_STRUCT_ID = 0x00
local M_SPRITE = 0x01
local M_Y_COORD = 0x02
local M_X_COORD = 0x03

local SRC_MAPOBJ = 0 -- the player's map object, used as a known-good template
local NUM_MAP_OBJECTS = 16 -- 16 map objects, but only 13 object structs
-- The destination is chosen at run time: the map's own objects fill low map-object slots even with no struct.
local TILE_OFFSET_X = 2
local SPAWN_AFTER_FRAMES = 120
local UNASSIGNED = 0xFF -- -1: "no object struct yet". The engine fills this in.

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/spawn_test2_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, never flushed per line: a flush is a synchronous disk write on the emulator's own thread.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- The console is a GUI append on the emulator's thread, so it gets the first lines and one in twenty; the file all.
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
		-- Flush every 20 lines: a bounded cost, and a log that is never empty for a whole run.
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
		return false, string.format("ROM title is %q, expected \"PM_CRYSTAL\"", table.concat(t))
	end
	if u8(0x14E, ROM_DOMAIN) ~= 0x12 or u8(0x14F, ROM_DOMAIN) ~= 0x9F then
		return false, "global checksum is not 129F (vanilla V1.0)"
	end
	return true, "vanilla Crystal V1.0"
end

open_log()
log("=== MeshGhost Crystal spawn test 2 — via the map object (WRITES RAM) ===")

local ok, why = rom_is_vanilla_v1()
if not ok then
	log("REFUSING TO WRITE: " .. why)
	return
end
log("ROM guard passed: " .. why)

-- The whole map-object array before touching it, so "already in use" is information, not a dead end.
local function dump_map_objects()
	log("Map objects (sprite 0 = free; the engine skips those):")
	for i = 0, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + (i * MAPOBJECT_LENGTH)
		local sprite = u8(base + M_SPRITE) or 0
		if sprite ~= 0 then
			log(string.format(
				"  %2d: sprite=%3d structId=%3d at %d,%d%s",
				i, sprite, u8(base + M_OBJECT_STRUCT_ID) or -1,
				u8(base + M_X_COORD) or -1, u8(base + M_Y_COORD) or -1,
				(i == 0) and "   <- player" or ""
			))
		end
	end
end

-- Pick the first genuinely free slot rather than assuming one. Skips 0 (the player).
local function find_free_map_object()
	for i = 1, NUM_MAP_OBJECTS - 1 do
		local sprite = u8(MAP_OBJECTS + (i * MAPOBJECT_LENGTH) + M_SPRITE)
		if sprite == 0 then
			return i
		end
	end
	return nil
end

local src = MAP_OBJECTS + (SRC_MAPOBJ * MAPOBJECT_LENGTH)
local DST_MAPOBJ, dst -- resolved once the map is loaded, in tick()

local frames, written, written_at = 0, false, 0
local adopted_reported = false

local function occupancy()
	local marks = {}
	for i = 0, NUM_OBJECT_STRUCTS - 1 do
		local s = u8(OBJECT_STRUCTS + (i * OBJECT_LENGTH))
		marks[#marks + 1] = (s and s ~= 0) and "X" or "."
	end
	return table.concat(marks)
end

-- An explicit frameadvance loop, not event.onframeend: a registered callback outlives its script, and every
-- reload stacks another.
local function tick()
	frames = frames + 1

	if not written then
		if frames < SPAWN_AFTER_FRAMES then
			return
		end

		dump_map_objects()

		DST_MAPOBJ = find_free_map_object()
		if not DST_MAPOBJ then
			log(string.format(
				"All %d map object slots are in use — nothing free on this map. Not writing.",
				NUM_MAP_OBJECTS
			))
			written = true
			return
		end
		dst = MAP_OBJECTS + (DST_MAPOBJ * MAPOBJECT_LENGTH)
		log(string.format("Chose free map object slot %d.", DST_MAPOBJ))

		-- The player's own map object, as a known-good template.
		local bytes = {}
		for off = 0, MAPOBJECT_LENGTH - 1 do
			bytes[off] = u8(src + off) or 0
		end
		for off = 0, MAPOBJECT_LENGTH - 1 do
			w8(dst + off, bytes[off])
		end

		local px = u8(src + M_X_COORD) or 0
		local py = u8(src + M_Y_COORD) or 0
		w8(dst + M_X_COORD, px + TILE_OFFSET_X)
		w8(dst + M_Y_COORD, py)

		-- The important byte: hand it to the engine unassigned and let it allocate the struct.
		w8(dst + M_OBJECT_STRUCT_ID, UNASSIGNED)

		written = true
		written_at = frames
		log(string.format(
			"Wrote map object %d at frame %d (player %d,%d -> ghost %d,%d), struct id left as -1.",
			DST_MAPOBJ, frames, px, py, px + TILE_OFFSET_X, py
		))
		log("Slots now: [" .. occupancy() .. "]")
		log(">>> NOW WALK. <<< The engine only looks for unadopted map objects at the moment the")
		log("player FINISHES a step: _CheckObjectEnteringVisibleRange returns immediately unless")
		log("PLAYERSTEP_STOP_F is set in wPlayerStepFlags. Standing still, it never runs.")
		return
	end

	local n = frames - written_at
	if n % 30 == 0 and n <= 600 and not adopted_reported then
		local id = u8(dst + M_OBJECT_STRUCT_ID)
		if id and id ~= UNASSIGNED then
			log(string.format(
				"*** ADOPTED at +%d frames: engine assigned object struct %d ***", n, id
			))
			log("Slots now: [" .. occupancy() .. "]")
			log("The game changed a value we did not write — it owns this object.")
			adopted_reported = true
		elseif n % 150 == 0 then
			log(string.format("  +%d frames: still -1, not adopted yet. Slots [%s]", n, occupancy()))
		end
	end
end

-- Registered before the loop, which never returns, and wrapped whole: an error inside onexit can leave the Lua
-- Console unable to start or stop the script, and memory domains may be invalid while the emulator tears down.
event.onexit(function()
	pcall(function()
		if not dst then
			return -- never picked a slot, so nothing to undo
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
