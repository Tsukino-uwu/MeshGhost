-- MeshGhost — Pokémon Crystal: spawn test 3, place it where the engine actually looks
--
-- *** WRITES GAME RAM. *** Same rules as the 2026-08-17 ADR: object RAM only, never a save,
-- cosmetic only, vanilla Crystal V1.0 only (guard below).
--
-- WHAT THE PREVIOUS TWO TESTS ESTABLISHED
--   1. Writing an object struct directly DOES render (confirmed on screen), but produces a
--      half-owned object: collision follows the map coords we set while the sprite stays frozen,
--      because the engine never recomputes it.
--   2. Writing a map object and waiting for adoption did nothing, for 600 frames of walking. The
--      dump explained why: the game's OWN objects in the same room (SPRITE_DOLL_1/2, BIG_DOLL)
--      were also sitting at structId 255. Nothing was being adopted, not just us.
--
-- WHY, from pokecrystal
-- `CheckObjectEnteringVisibleRange` is not a general "adopt anything unassigned" pass. It is
-- specifically "spawn objects as they scroll onto the screen edge":
--
--     .Down:  d = wYCoord + 9      ; the row just below the visible area
--     .Up:    d = wYCoord - 1      ; the row just above it
--             then match map objects whose Y_COORD == d and structId == -1
--
-- and it returns immediately unless wPlayerStepDirection is not STANDING. So it scans exactly one
-- row, the one about to come into view. An object placed beside the player is already inside the
-- screen and can never match, however far you walk. That is why test 2 sat unadopted forever, and
-- it was a property of WHERE we put it, not of what we wrote.
--
-- WHAT THIS TEST DOES, and what it is really asking
-- Places the ghost on the row the engine scans -- directly BELOW the visible area -- and asks you
-- to walk DOWN so that row scrolls in. This is deliberately not how a real ghost would be
-- positioned. It is a controlled question:
--
--     "Are the bytes we write acceptable to the engine's own adoption path?"
--
-- Separating that from "is the trigger firing?" is the whole point -- one variable at a time.
--   * If it IS adopted: our map object is legitimate, the engine will drive it, and the remaining
--     problem is only that we need adoption to happen at an arbitrary position. That is then a
--     question about how to invoke the path, not whether our data is right.
--   * If it is NOT adopted even on the correct row: something in our bytes is unacceptable, and
--     the next step is comparing them field by field against one of the dolls.
--
-- HOW TO RUN
--   1. Load a save, be in the overworld, ideally somewhere with room to walk down a few tiles.
--   2. Lua Console -> Script -> Open, pick this file. Wait ~2 seconds.
--   3. *** WALK DOWN *** several steps. Down specifically -- the placement is below you.
--      Log: spawn_test3_<timestamp>.log beside this script.

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

-- The row CheckObjectEnteringVisibleRange scans when walking down, straight from the decomp.
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
end

local raw_log = console.log
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
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

		-- Place it on the row the engine will scan when the player walks DOWN. Coordinates come
		-- from wXCoord/wYCoord, which is the space CheckObjectEnteringVisibleRange compares
		-- against -- not from the player's map object, whose coords are its spawn position.
		local px, py = u8(W_XCOORD) or 0, u8(W_YCOORD) or 0
		local gy = py + BELOW_SCREEN_DY
		w8(dst + M_X_COORD, px)
		w8(dst + M_Y_COORD, gy)
		w8(dst + M_OBJECT_STRUCT_ID, UNASSIGNED)

		written = true
		written_at = frames
		log(string.format(
			"Wrote map object %d: sprite copied from player, at %d,%d (player is at %d,%d).",
			DST, px, gy, px, py
		))
		log(">>> WALK DOWN. <<< The engine scans the row at wYCoord+9 as it scrolls into view,")
		log("and only while a step is in progress. Beside the player it would never be seen.")
		return
	end

	if adopted then
		return
	end

	local id = u8(dst + M_OBJECT_STRUCT_ID)
	if id and id ~= UNASSIGNED then
		adopted = true
		log(string.format("*** ADOPTED at +%d frames: engine assigned object struct %d ***",
			frames - written_at, id))
		log("The game changed a value we did not write. Our map object is legitimate.")
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
