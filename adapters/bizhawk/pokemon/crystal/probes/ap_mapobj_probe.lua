-- MeshGhost — Crystal/Archipelago: find wMapObjects by matching it against wObjectStructs
--
-- READ-ONLY. Writes nothing, spawns nothing.
--
-- WHY
-- wObjectStructs is CONFIRMED at 0x14DC on this ROM (vanilla+6): slot 0 holds a sprite and the
-- player's coordinates on both axes, the map's NPCs sit in the low slots, and everything after
-- them is zero (verified.md, 2026-08-18).
--
-- wMapObjects does NOT follow from it. In the vanilla build it sits 0x248 after wObjectStructs,
-- and that address on this ROM is noise -- struct_id=255, sprite=0, y=255. Which is the third time
-- this session that a fixed vanilla relationship failed on the patched build: the coordinate block
-- moved +7, the object array moved +6, so the two tables were NOT shifted together. Anything
-- derived from "vanilla + a delta measured somewhere else" is a guess.
--
-- HOW
-- The struct array itself says what the map-object table must contain. Each live struct carries a
-- sprite id and a MAP_OBJECT_INDEX pointing at its entry, so for slot i with sprite s and index m,
-- the real table has s at entry m. Two or more live NPCs make that a multi-point constraint, and
-- a coincidence would have to satisfy all of them at the same stride.
--
-- The entry OFFSET of the sprite field is searched rather than assumed: AP rearranges where things
-- live, and if it also changed the entry layout, a hard-coded 0x01 would report nothing and look
-- like a failed search rather than a wrong assumption.
--
-- COST
-- WRAM is snapshotted ONCE into a Lua table, then scanned in pure Lua. A nested scan over the
-- emulator API would be ~1M boundary crossings, which is the shape that silently stalls the host
-- and produces no log at all (probes.md, "A probe's read budget is real").
--
-- HOW TO RUN
--   1. Load the ARCHIPELAGO Crystal ROM. Stand in the overworld on a map with at least two NPCs
--      visible -- the probe says how many live structs it found, and one is not enough to be sure.
--   2. Lua Console -> Script -> Open, pick this file. It reports immediately; no walking needed.
--      Log: ap_mapobj_<timestamp>.log beside this script. The console gets the summary only.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000

local OBJECT_STRUCTS = 0x14DC -- CONFIRMED on this ROM, not derived
local VANILLA_MAPOBJECTS_DELTA = 0x248 -- vanilla 0xD71E - 0xD4D6, reported for comparison only

local F_SPRITE, F_MAP_OBJECT_INDEX = 0x00, 0x01
local F_MAP_X, F_MAP_Y = 0x10, 0x11
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

local logfile = io.open(string.format("%s/ap_mapobj_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

-- The last dump flooded the Lua Console with three full tables. Detail goes to the file; the
-- console gets headlines only.
local function log(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

local function say(msg)
	console.log(msg)
	log(msg)
end

say("=== MeshGhost Crystal/AP wMapObjects probe (READ-ONLY) ===")
say("Detail goes to the log file beside this script; the console gets the summary.")

-- One snapshot, one boundary crossing per byte.
local ram = {}
for a = 0, WRAM_SIZE - 1 do
	local ok, v = pcall(memory.read_u8, a, DOMAIN)
	ram[a] = (ok and type(v) == "number") and v or 0
end

-- What the confirmed struct array says must exist somewhere.
local want = {} -- { index = m, sprite = s }
for i = 0, NUM_OBJECT_STRUCTS - 1 do
	local s = OBJECT_STRUCTS + i * OBJECT_LENGTH
	local sprite, idx = ram[s + F_SPRITE], ram[s + F_MAP_OBJECT_INDEX]
	if sprite and sprite ~= 0 and idx and idx < NUM_MAP_OBJECTS then
		want[#want + 1] = { index = idx, sprite = sprite, slot = i,
			x = ram[s + F_MAP_X], y = ram[s + F_MAP_Y] }
		log(string.format("  struct slot %d: sprite=%d -> map object entry %d (at x=%d y=%d)",
			i, sprite, idx, ram[s + F_MAP_X] or -1, ram[s + F_MAP_Y] or -1))
	end
end

say(string.format("%d live struct(s) to match against.", #want))
if #want < 2 then
	say("!! Fewer than two live objects. Stand on a map with NPCs and re-run -- a single")
	say("!! constraint will match a lot of unrelated bytes and prove nothing.")
	return
end

-- Search both the table base AND the sprite field's offset within an entry.
local hits = {}
for f = 0, MAPOBJECT_LENGTH - 1 do
	for mo = 0, WRAM_SIZE - NUM_MAP_OBJECTS * MAPOBJECT_LENGTH - 1 do
		local all = true
		for _, w in ipairs(want) do
			if ram[mo + w.index * MAPOBJECT_LENGTH + f] ~= w.sprite then
				all = false
				break
			end
		end
		if all then
			hits[#hits + 1] = { base = mo, spriteOffset = f }
		end
	end
end

say(string.format("%d candidate table(s) satisfy every constraint.", #hits))
for _, h in ipairs(hits) do
	say(string.format("  0x%04X (%d), sprite at entry offset 0x%02X  [vanilla-relative delta from"
		.. " wObjectStructs: %+d, vanilla is +0x%03X]",
		h.base, h.base, h.spriteOffset, h.base - OBJECT_STRUCTS, VANILLA_MAPOBJECTS_DELTA))
	log(string.format("--- 0x%04X in full, %d entries of 0x%02X ---",
		h.base, NUM_MAP_OBJECTS, MAPOBJECT_LENGTH))
	for i = 0, NUM_MAP_OBJECTS - 1 do
		local e = h.base + i * MAPOBJECT_LENGTH
		local bytes = {}
		for o = 0, MAPOBJECT_LENGTH - 1 do
			bytes[#bytes + 1] = string.format("%02X", ram[e + o] or 0)
		end
		log(string.format("  entry %2d: %s", i, table.concat(bytes, " ")))
	end
end

if #hits == 0 then
	say("!! Nothing matched. That is a result, not a malfunction: it would mean the entry stride")
	say("!! is not 0x10 on this build, or MAP_OBJECT_INDEX does not index the table the way the")
	say("!! vanilla layout says. Re-run on a busier map before concluding either.")
else
	say("Read the full entries in the log: the real table repeats a fixed layout, and the")
	say("coordinates in each entry should sit near the matching struct's x/y printed above.")
end
