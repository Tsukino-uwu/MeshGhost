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
local DST_MAPOBJ = 1 -- wMap1Object
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

local src = MAP_OBJECTS + (SRC_MAPOBJ * MAPOBJECT_LENGTH)
local dst = MAP_OBJECTS + (DST_MAPOBJ * MAPOBJECT_LENGTH)

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

event.onframeend(function()
	frames = frames + 1

	if not written then
		if frames < SPAWN_AFTER_FRAMES then
			return
		end

		local existing = u8(dst + M_SPRITE)
		if existing and existing ~= 0 then
			log(string.format(
				"Map object %d already in use (sprite=%d) — not writing. Try a quieter map.",
				DST_MAPOBJ, existing
			))
			written = true
			return
		end

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
		log("Waiting for the ENGINE to assign an object struct...")
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
end)

event.onexit(function()
	-- Leave nothing behind: clear the map object, and the struct the engine may have assigned.
	local id = u8(dst + M_OBJECT_STRUCT_ID)
	if id and id ~= UNASSIGNED and id < NUM_OBJECT_STRUCTS then
		w8(OBJECT_STRUCTS + (id * OBJECT_LENGTH), 0)
	end
	for off = 0, MAPOBJECT_LENGTH - 1 do
		w8(dst + off, 0)
	end
end)
