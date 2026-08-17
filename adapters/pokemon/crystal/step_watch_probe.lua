-- MeshGhost — Pokémon Crystal: watch a real NPC take a step
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, spawns nothing.
--
-- WHY THIS EXISTS
-- Spawning is solved (phase9.md): a player-looking character can be created anywhere, and the
-- engine renders and animates it for free. What is NOT solved is MOVEMENT. A peer's ghost has to
-- go where the peer goes, and there are two ways that could work:
--
--   * Write the ghost's MAP_X/MAP_Y each time it should move. Simple, and likely to make it snap
--     between tiles instead of walking, because a step in this game is a multi-frame process.
--   * Ask the game to TAKE A STEP, and let its own machinery walk the object.
--
-- The second is almost certainly right -- it is the same "trigger the game's own systems" lesson
-- that produced the whole spawn recipe -- but nobody has yet watched what a step actually consists
-- of. This does that, and changes nothing while doing it.
--
-- WHAT IT WATCHES
-- A wandering NPC on the current map, every frame, reporting only the fields that CHANGE. One step
-- should read as a short timeline: something initiates it, some fields count down, the sprite
-- coordinates slide, and the map coordinates update once at some point in that sequence. Which
-- field moves FIRST is the interesting part, because that is the one to write.
--
-- HOW TO RUN
--   1. Stand in the overworld with a wandering NPC in view. Elm's lab is ideal -- the aides pace
--      on their own, so steps happen without you doing anything.
--   2. Lua Console -> Script -> Open, pick this file. Watch for a few seconds.
--      Log: step_watch_<timestamp>.log beside this script.
--
-- Reading the log: each line is one frame in which something changed. A blank stretch means the
-- NPC is standing still. The block between two "map coords changed" lines is one whole step.

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

local OBJECT_STRUCTS = flat(0xD4D6)
local MAP_OBJECTS = flat(0xD71E)
local OBJECT_LENGTH = 0x28
local MAPOBJECT_LENGTH = 0x10
local NUM_OBJECT_STRUCTS = 13
local NUM_MAP_OBJECTS = 16
local M_OBJECT_STRUCT_ID, M_SPRITE = 0x00, 0x01
local F_SPRITE = 0x00
local UNASSIGNED = 0xFF

-- The fields plausibly involved in a step, from constants/map_object_constants.asm. Watching a
-- superset deliberately: the point is to find out which ones matter, so filtering first would be
-- a guess about the answer -- the template's "dump everything" rule.
local WATCH = {
	{ 0x03, "MOVEMENT_TYPE" }, { 0x04, "FLAGS1" }, { 0x05, "FLAGS2" },
	{ 0x07, "WALKING" }, { 0x08, "DIRECTION" }, { 0x09, "STEP_TYPE" },
	{ 0x0A, "STEP_DURATION" }, { 0x0B, "ACTION" }, { 0x0C, "STEP_FRAME" },
	{ 0x0D, "FACING" }, { 0x0E, "TILE_COLLISION" }, { 0x0F, "LAST_TILE" },
	{ 0x10, "MAP_X" }, { 0x11, "MAP_Y" }, { 0x12, "LAST_MAP_X" }, { 0x13, "LAST_MAP_Y" },
	{ 0x17, "SPRITE_X" }, { 0x18, "SPRITE_Y" },
	{ 0x19, "SPRITE_X_OFFSET" }, { 0x1A, "SPRITE_Y_OFFSET" },
	{ 0x1B, "MOVEMENT_INDEX" }, { 0x1C, "STEP_INDEX" },
}

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/step_watch_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end

local raw_log = console.log
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
	end
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

-- Same identity guard the other scripts use: an object wearing the player's sprite is one of ours
-- from another script, not an engine NPC.
local function find_wandering_npc()
	local player_sprite = u8(OBJECT_STRUCTS + F_SPRITE)
	for i = 1, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + (i * MAPOBJECT_LENGTH)
		local sprite = u8(base + M_SPRITE) or 0
		local id = u8(base + M_OBJECT_STRUCT_ID)
		if sprite ~= 0 and id and id ~= UNASSIGNED and id < NUM_OBJECT_STRUCTS
			and sprite ~= player_sprite then
			return i, id
		end
	end
end

open_log()
log("=== MeshGhost Crystal step watch (READ-ONLY) ===")
log("Watching one wandering NPC. Prints only frames where something changed.")

local frames, base, prev = 0, nil, {}
local steps_seen = 0

local function tick()
	frames = frames + 1

	if not base then
		if frames < 60 then
			return
		end
		local mo, st = find_wandering_npc()
		if not mo then
			log("No engine-driven NPC found. Move somewhere with a person and restart.")
			base = -1
			return
		end
		base = OBJECT_STRUCTS + (st * OBJECT_LENGTH)
		log(string.format("Watching map object %d -> struct %d (sprite %d).",
			mo, st, u8(MAP_OBJECTS + (mo * MAPOBJECT_LENGTH) + M_SPRITE) or -1))
		for _, f in ipairs(WATCH) do
			prev[f[1]] = u8(base + f[1])
		end
		return
	end
	if base == -1 then
		return
	end

	local changes = {}
	local moved = false
	for _, f in ipairs(WATCH) do
		local now = u8(base + f[1])
		if now ~= prev[f[1]] then
			changes[#changes + 1] = string.format("%s %s->%s", f[2], tostring(prev[f[1]]), tostring(now))
			if f[1] == 0x10 or f[1] == 0x11 then
				moved = true
			end
			prev[f[1]] = now
		end
	end

	if #changes > 0 then
		log(string.format("  f=%-6d %s", frames, table.concat(changes, "  ")))
		if moved then
			steps_seen = steps_seen + 1
			log(string.format("  ^^^ MAP COORDS CHANGED — end of step %d ^^^", steps_seen))
		end
	end
end

while true do
	tick()
	emu.frameadvance()
end
