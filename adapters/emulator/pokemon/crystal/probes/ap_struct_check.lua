-- MeshGhost — Crystal/Archipelago: fingerprint the wObjectStructs candidate
--
-- READ-ONLY. Writes nothing, spawns nothing.
--
-- WHY
-- ap_address_probe.lua narrowed wObjectStructs to three survivors on this ROM (2026-08-18):
--
--   0x14DC  vanilla+6     sprite=1   <- the prediction, and the only one with a sprite id
--   0x14DE  vanilla+8     sprite=0
--   0x1CAF  vanilla+2009  sprite=0
--
-- Two things make that result weaker than it looks, and this probe exists to fix both:
--
--   1. All three of its steps were on the SAME axis (-1,+0). A byte pair that happens to shadow
--      X can survive three identical steps; it cannot survive both axes.
--   2. "The tidiest survivor" is a judgement, not a measurement. 0x14DE is exactly the
--      LAST_MAP_X/LAST_MAP_Y pair two bytes along, which is precisely the kind of lookalike this
--      project keeps mistaking for the real thing.
--
-- So this checks the STRUCTURE around each candidate, which a coincidence cannot fake:
--
--   - slot 0 is the player: sprite id non-zero, and MAP_X/MAP_Y follow the player on BOTH axes.
--   - a 0x28 stride produces a sane array: the map's NPCs in the low slots, zeroes after them,
--     and each slot's MAP_OBJECT_INDEX pointing somewhere plausible.
--   - wMapObjects sits 0x248 after the base in the vanilla build, and each map-object entry's
--     STRUCT_ID should point back at a live struct slot. A base that is off by a couple of bytes
--     scrambles this immediately.
--
-- HOW TO RUN
--   1. Load the ARCHIPELAGO Crystal ROM, be in the overworld somewhere with a few NPCs about
--      (a town or a Pokemon Center is ideal — an empty room proves less).
--   2. Lua Console -> Script -> Open, pick this file.
--   3. WALK: a few tiles left or right, THEN a few tiles up or down. Both axes matter.
--      The probe reports once it has seen the player move on each axis.
--      Log: ap_struct_<timestamp>.log beside this script.

local DOMAIN = "WRAM"

-- MEASURED by ap_reverse_probe.lua, one run per axis (verified.md, 2026-08-18).
local AP_YCOORD, AP_XCOORD = 7358, 7359

-- 0x1CAF was ELIMINATED 2026-08-18: it followed X 15 times and Y zero times, because
-- 0x1CAF + F_MAP_X is 0x1CBF, the X coordinate itself. It was a shadow of the coordinate block.
-- 0x14DE cannot be eliminated by walking at all -- it is the LAST_MAP_X/LAST_MAP_Y pair two bytes
-- along, so it tracks both axes by construction. Structure is the only thing that separates it
-- from 0x14DC, and structure needs no movement, which is why the dump now runs at load.
local CANDIDATES = { 0x14DC, 0x14DE }
local VANILLA_OBJECT_STRUCTS = 0x14D6
local MAPOBJECTS_DELTA = 0x248 -- vanilla 0xD71E - 0xD4D6

-- Field offsets from the working vanilla adapter (meshghost_crystal.lua), not from memory.
local F_SPRITE, F_MAP_OBJECT_INDEX = 0x00, 0x01
local F_MAP_X, F_MAP_Y = 0x10, 0x11
local M_STRUCT_ID, M_SPRITE, M_Y, M_X = 0x00, 0x01, 0x02, 0x03
local OBJECT_LENGTH, MAPOBJECT_LENGTH = 0x28, 0x10
local NUM_OBJECT_STRUCTS, NUM_MAP_OBJECTS = 13, 16

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		local d = info.source:sub(2):match("^(.*)[/\\]")
		if d and #d > 0 then
			return d
		end
	end
	return "."
end

local logfile = io.open(string.format("%s/ap_struct_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		-- Flush every 20 LINES: bounded cost, live log. The buffering sweep removed the per-line
		-- flush and a probe then reported NOTHING for a whole run (pitfalls.md: an empty log reads
		-- exactly like "nothing happened").
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
	end
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

log("=== MeshGhost Crystal/AP wObjectStructs fingerprint (READ-ONLY) ===")

-- Phase 1: watch each candidate's slot 0 track the player on both axes.
local tracked = {} -- candidate -> { x = n, y = n, missX = n, missY = n }
for _, base in ipairs(CANDIDATES) do
	tracked[base] = { x = 0, y = 0, missX = 0, missY = 0 }
end

local prevX, prevY = u8(AP_XCOORD), u8(AP_YCOORD)
local prevSlot = {}
for _, base in ipairs(CANDIDATES) do
	prevSlot[base] = { u8(base + F_MAP_X), u8(base + F_MAP_Y) }
end

local frames, done = 0, false

local function dumpArray(base)
	log(string.format("--- 0x%04X (vanilla%+d) as an array of %d x 0x%02X ---",
		base, base - VANILLA_OBJECT_STRUCTS, NUM_OBJECT_STRUCTS, OBJECT_LENGTH))
	local live = 0
	for i = 0, NUM_OBJECT_STRUCTS - 1 do
		local s = base + i * OBJECT_LENGTH
		local sprite = u8(s + F_SPRITE) or 0
		if sprite ~= 0 then
			live = live + 1
		end
		log(string.format("  slot %2d  sprite=%3d  mapobj=%3d  x=%3d y=%3d",
			i, sprite, u8(s + F_MAP_OBJECT_INDEX) or -1,
			u8(s + F_MAP_X) or -1, u8(s + F_MAP_Y) or -1))
	end
	log(string.format("  %d of %d slots hold a sprite.", live, NUM_OBJECT_STRUCTS))

	local mo = base + MAPOBJECTS_DELTA
	log(string.format("--- its wMapObjects would be 0x%04X (+0x%03X), %d x 0x%02X ---",
		mo, MAPOBJECTS_DELTA, NUM_MAP_OBJECTS, MAPOBJECT_LENGTH))
	local sane = 0
	for i = 0, NUM_MAP_OBJECTS - 1 do
		local m = mo + i * MAPOBJECT_LENGTH
		local id, sprite = u8(m + M_STRUCT_ID) or 255, u8(m + M_SPRITE) or 0
		if sprite ~= 0 and id < NUM_OBJECT_STRUCTS then
			sane = sane + 1
		end
		log(string.format("  entry %2d  struct_id=%3d  sprite=%3d  y=%3d x=%3d",
			i, id, sprite, u8(m + M_Y) or -1, u8(m + M_X) or -1))
	end
	log(string.format("  %d entry(ies) have a sprite AND a struct_id inside the array.", sane))
end

log("=== STRUCTURE AT LOAD — no walking needed for this half ===")
log("The real base has a sprite in slot 0, the map's NPCs in low slots, zeroes after them, and a")
log("+0x248 table pointing back into the array. A base a couple of bytes off scrambles all three.")
log("")
for _, base in ipairs(CANDIDATES) do
	dumpArray(base)
	log("")
end
log("=== NOW WALK: a few tiles one axis, a few the other, to re-confirm slot 0 is the player ===")

local function tick()
	frames = frames + 1
	if done or frames % 4 ~= 0 then
		return
	end

	local x, y = u8(AP_XCOORD), u8(AP_YCOORD)
	if not x or not y then
		return
	end
	local dx, dy = x - (prevX or x), y - (prevY or y)

	if dx ~= 0 or dy ~= 0 then
		-- one tile on one axis, or it is a warp/load and only re-baselines
		if math.abs(dx) + math.abs(dy) == 1 then
			for _, base in ipairs(CANDIDATES) do
				local nx, ny = u8(base + F_MAP_X), u8(base + F_MAP_Y)
				local was = prevSlot[base]
				local t = tracked[base]
				local okx = (nx and was[1]) and (nx - was[1]) == dx
				local oky = (ny and was[2]) and (ny - was[2]) == dy
				if dx ~= 0 then
					if okx and oky then t.x = t.x + 1 else t.missX = t.missX + 1 end
				else
					if okx and oky then t.y = t.y + 1 else t.missY = t.missY + 1 end
				end
			end
		end
		prevX, prevY = x, y
		for _, base in ipairs(CANDIDATES) do
			prevSlot[base] = { u8(base + F_MAP_X), u8(base + F_MAP_Y) }
		end

		local ready = false
		for _, base in ipairs(CANDIDATES) do
			local t = tracked[base]
			if t.x >= 2 and t.y >= 2 then
				ready = true
			end
		end
		if not ready then
			local parts = {}
			for _, base in ipairs(CANDIDATES) do
				local t = tracked[base]
				parts[#parts + 1] = string.format("0x%04X x%d/y%d", base, t.x, t.y)
			end
			log("  tracking: " .. table.concat(parts, "  "))
			return
		end

		log("=== BOTH AXES SEEN ===")
		for _, base in ipairs(CANDIDATES) do
			local t = tracked[base]
			log(string.format("  0x%04X  followed X %d time(s), Y %d time(s), missed %d/%d",
				base, t.x, t.y, t.missX, t.missY))
		end
		log("A base that misses an axis is a shadow of one coordinate, not an object struct.")
		log("Both of these are expected to pass this half — read the structure dump above for the")
		log("half that actually separates them.")
		done = true
	end
end

while true do
	tick()
	emu.frameadvance()
end
