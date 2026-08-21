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
--   1. Best capture found so far, and it repeats on demand: the NPC standing OUTSIDE Elm's lab.
--      Talk to them -- they get angry, step BACK, then PUSH the player, and the player cannot move
--      during it. That is a scripted movement sequence driving both an NPC and the player, which
--      is precisely the machinery a ghost needs: a character walked to a place while not under
--      input control. Repeatable, short, and it exercises both objects at once.
--      A wandering NPC (Elm's aides pace on their own) works too, for a plain unscripted step.
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

-- Watch EVERY object the engine is driving, not one picked arbitrarily. The first version chose
-- the first NPC it found, which may be a stationary one -- and a probe that watches the wrong
-- object reports "nothing happened" indistinguishably from "nothing happens". Cheap to watch all
-- of them, and it guarantees the one that moves is captured.
--
-- The player (struct 0) is included deliberately: during a scripted cutscene the game walks the
-- PLAYER around too, and that is the same movement machinery driving a character that is not
-- under input control -- which is exactly the situation a ghost is in.
local function engine_objects()
	local out = {}
	for i = 0, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + (i * MAPOBJECT_LENGTH)
		local sprite = u8(base + M_SPRITE) or 0
		local id = u8(base + M_OBJECT_STRUCT_ID)
		if sprite ~= 0 and id and id ~= UNASSIGNED and id < NUM_OBJECT_STRUCTS then
			out[#out + 1] = { mo = i, st = id, sprite = sprite,
				label = (i == 0) and "PLAYER" or string.format("npc%d", i) }
		end
	end
	return out
end

open_log()
log("=== MeshGhost Crystal step watch (READ-ONLY) ===")
log("Watching every engine-driven object, the player included. Prints only frames that changed.")

local frames, watched = 0, nil
local steps_seen = 0

local function tick()
	frames = frames + 1

	-- Re-scan periodically as well as at the start: a cutscene can bring objects in and out, and
	-- a watcher fixed at startup would miss whoever arrives to shove the player around.
	if not watched or frames % 300 == 0 then
		local found = engine_objects()
		if #found == 0 then
			if not watched then
				log("No engine-driven objects yet.")
			end
			return
		end
		local fresh = {}
		for _, o in ipairs(found) do
			local key = o.st
			local existing = watched and watched[key]
			o.base = OBJECT_STRUCTS + (o.st * OBJECT_LENGTH)
			o.prev = existing and existing.prev or {}
			if not existing then
				for _, f in ipairs(WATCH) do
					o.prev[f[1]] = u8(o.base + f[1])
				end
				log(string.format("Now watching %s (map object %d -> struct %d, sprite %d).",
					o.label, o.mo, o.st, o.sprite))
			end
			fresh[key] = o
		end
		watched = fresh
		return
	end

	for _, o in pairs(watched) do
		local changes, moved = {}, false
		for _, f in ipairs(WATCH) do
			local now = u8(o.base + f[1])
			if now ~= o.prev[f[1]] then
				changes[#changes + 1] =
					string.format("%s %s->%s", f[2], tostring(o.prev[f[1]]), tostring(now))
				if f[1] == 0x10 or f[1] == 0x11 then
					moved = true
				end
				o.prev[f[1]] = now
			end
		end
		if #changes > 0 then
			log(string.format("  f=%-6d [%-6s] %s", frames, o.label, table.concat(changes, "  ")))
			if moved then
				steps_seen = steps_seen + 1
				log(string.format("  ^^^ [%s] MAP COORDS CHANGED — step %d complete ^^^",
					o.label, steps_seen))
			end
		end
	end
end

while true do
	tick()
	emu.frameadvance()
end
