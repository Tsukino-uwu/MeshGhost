-- Fingerprints the Archipelago wObjectStructs candidates by structure, which a coincidence cannot fake: slot 0 is the
-- player on both axes, a 0x28 stride gives a sane array, wMapObjects entries point back. Read-only. Run on the AP ROM
-- where there are NPCs; the dump runs at load, then walk a few tiles on each axis. Logs ap_struct_<timestamp>.log.

local DOMAIN = "WRAM"

-- Measured by reversal (ap_reverse_probe.lua).
local AP_YCOORD, AP_XCOORD = 7358, 7359

-- 0x14DE is the LAST_MAP_X/LAST_MAP_Y pair two bytes along, so it tracks both axes by construction: only structure
-- separates it from 0x14DC, and structure needs no walking, so the dump runs at load.
local CANDIDATES = { 0x14DC, 0x14DE }
local VANILLA_OBJECT_STRUCTS = 0x14D6
local MAPOBJECTS_DELTA = 0x248 -- vanilla 0xD71E - 0xD4D6

-- Field offsets from meshghost_crystal.lua, not from memory.
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
		-- Every 20 lines, never per line: bounded cost, and the log stays live through a run.
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
		-- One tile on one axis, or it is a warp or a load and only re-baselines.
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
