-- MeshGhost — Pokémon Crystal: spawn test 2, via the MAP OBJECT instead of the object struct
--
-- *** WRITES GAME RAM. *** Same rules as spawn_test.lua and the 2026-08-17 ADR: object RAM only,
-- never a save, cosmetic only, vanilla Crystal V1.0 only (guard below).
--
-- WHY THERE IS A SECOND TEST
-- spawn_test.lua worked and taught us something better than success. Writing an object struct
-- directly DID render a character (confirmed on screen 2026-08-18) but produced a half-owned
-- object: collision sat at the map coordinates we set, while the sprite stayed frozen at the
-- screen position copied from the player, because the engine never recomputed it. The user saw
-- both halves -- a visible character in one place, an invisible blocked tile two tiles away.
--
-- Reading pokecrystal explains it. Object structs are not the source of truth; MAP OBJECTS are.
-- `InitializeVisibleSprites` walks the map objects, and for each one that has a sprite and whose
-- MAPOBJECT_OBJECT_STRUCT_ID is still -1, it assigns an object struct and takes ownership. We
-- skipped that entirely and wrote the downstream copy, so nothing maintained it.
--
-- So this test writes the thing the game actually reads, and then gets out of the way. That is
-- the ADR's "use the engine's own path" branch rather than imitating its output.
--
-- WHAT COUNTS AS SUCCESS, and it is not "a sprite appeared"
-- We set MAPOBJECT_OBJECT_STRUCT_ID to -1 ourselves. If the ENGINE replaces it with a real slot
-- number, the game has adopted the object -- a value we did not write, changed by the game. That
-- is the independent check spawn_test.lua lacked. The visual is still the final word: the
-- character should now stay with its own collision instead of drifting from it.
--
-- HOW TO RUN
--   1. Load a save, stand in the overworld. Stop any other MeshGhost script first.
--   2. Lua Console -> Script -> Open, pick this file. Wait ~2 seconds.
--   3. Walk around and watch whether sprite and collision stay together.
--      Log: spawn_test2_<timestamp>.log beside this script.

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

-- map_object fields (constants/map_object_constants.asm)
local M_OBJECT_STRUCT_ID = 0x00
local M_SPRITE = 0x01
local M_Y_COORD = 0x02
local M_X_COORD = 0x03

local SRC_MAPOBJ = 0 -- the player's map object, used as a known-good template
local NUM_MAP_OBJECTS = 16 -- NUM_OBJECTS. NOTE: 16 map objects but only 13 object structs.
-- DST_MAPOBJ is CHOSEN AT RUNTIME, not hardcoded. The first attempt used slot 1 and was refused
-- because the player's bedroom already has a map object there: sprite 240 = SPRITE_CONSOLE, the
-- console in the room. Map objects are what the MAP defines, so the low slots are occupied on
-- essentially every real map, and they are occupied even when the object currently has no object
-- struct -- which is why the struct-occupancy view showed "1 used" while map object 1 was taken.
-- Two different arrays, two different questions. Found live 2026-08-18.
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
	-- Buffered, and never flushed per line: a console.log plus a flush is a synchronous disk
	-- write on the emulator's own thread, measured at 63-83ms -- four to five frames, every time
	-- (pitfalls.md, "ONE console line a second cost 7.4 fps"). A probe that stalls the game is a
	-- probe that changes what it measures.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- THE CONSOLE IS THE EXPENSIVE HALF. `console.log` appends to BizHawk's GUI console window, on the
-- emulator's own thread; pitfalls.md measured ONE such line a second costing 7.4fps, and removing
-- the per-line disk flush alone left 87-175ms hitches still there (2026-08-21). So the console gets
-- the opening lines and then one in twenty, while the FILE gets every line -- the log is the record,
-- the console is only a glance.
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

-- Show the whole map-object array before touching it. This is the view that was missing when
-- slot 1 was hardcoded: without it, "already in use" is a dead end rather than information.
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

-- Driven by an explicit frameadvance loop, NOT event.onframeend. This is the idiom the shipped
-- Emerald adapter uses, and the reason matters: a registered event callback OUTLIVES the script
-- that registered it, so stopping the script leaves it firing and every reload stacks another
-- copy. Found live 2026-08-18 -- the console kept spamming while the Lua Console showed the
-- script red and "0 active", and start/stop did nothing. A while loop dies with the script.
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

		-- Copy the player's own map object as a known-good template, same reasoning as test 1.
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

		-- The important byte: hand it to the engine unassigned and let IT allocate the struct.
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

-- Cleanup, registered BEFORE the loop below, which never returns. Wrapped whole because an error
-- thrown inside onexit can leave BizHawk's Lua Console unable to start or stop the script at all
-- -- red icon, "0 active", toggling does nothing. Memory domains are not guaranteed valid while
-- the emulator is tearing down, so nothing in here may throw. Both found live 2026-08-18.
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
