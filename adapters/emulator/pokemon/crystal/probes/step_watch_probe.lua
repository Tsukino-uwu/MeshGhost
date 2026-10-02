-- Watches every engine-driven object's step fields, logging only the frames that changed. Read-only. Run beside a
-- moving NPC (the one outside Elm's lab steps and shoves the player when talked to); logs step_watch_<timestamp>.log.

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

-- A superset on purpose: filtering before looking would be a guess about which fields matter.
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
	-- Buffered, never flushed per line: a flush is a synchronous disk write on the emulator's own thread.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- console.log is a GUI append on the emulator's own thread and costs frames: it gets the first lines and one in twenty.
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

-- Every engine-driven object, the player included: one stationary NPC would read as "nothing happens", and a
-- cutscene walks the player with the same machinery a ghost needs.
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

	-- Re-scanned periodically: a cutscene brings objects in and out.
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
