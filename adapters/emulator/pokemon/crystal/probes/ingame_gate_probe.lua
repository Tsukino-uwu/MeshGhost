-- "Is the player actually in the game?": the game's own state bytes, logged on change, with what a gate asking "does
-- the world exist and is it stable" would decide. Read-only. Spawning while the game rebuilds object RAM corrupts it,
-- and stale slots look plausible on the main menu. Start it there, load a save, walk, open START, take a door and a
-- battle; logs ingame_gate_<timestamp>.log beside this script.

local DOMAIN = "WRAM"

-- The flat WRAM domain lays the banks end to end: $C000 bank 0 at 0x0000, $D000 bank 1 at 0x1000.
local function to_flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

local WATCH = {
	{ name = "wMapStatus", addr = to_flat(0xD432) },
	{ name = "wMapEventStatus", addr = to_flat(0xD433) },
	{ name = "wScriptRunning", addr = to_flat(0xD438) },
	{ name = "wGameLogicPaused", addr = to_flat(0xC2CD) },
	{ name = "wMapGroup", addr = to_flat(0xDCB5) },
	{ name = "wMapNumber", addr = to_flat(0xDCB6) },
	{ name = "wPlayerStepFlags", addr = to_flat(0xD150) },
	-- 0 none, 1 WILD_BATTLE, 2 TRAINER_BATTLE.
	{ name = "wBattleMode", addr = to_flat(0xD22D) },
}

local BATTLE = { [0] = "-", [1] = "wild", [2] = "trainer" }

local MAPSTATUS = { [0] = "START", [1] = "ENTER", [2] = "HANDLE", [3] = "DONE" }

-- Slot 0 holds the player, empty until the game spawns them: a cross-check on the state bytes.
local OBJECT_STRUCTS = to_flat(0xD4D6)
local OBJECT_LENGTH = 0x28
local NUM_OBJECT_STRUCTS = 13

-- Map objects are a separate array (what the map defines, not what the engine drives), watched on their own.
local MAP_OBJECTS = to_flat(0xD71E)
local MAPOBJECT_LENGTH = 0x10
local NUM_MAP_OBJECTS = 16
local M_SPRITE = 0x01

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/ingame_gate_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, never flushed per line: a flush stalls the emulator's own thread, and the probe with it.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- The console is a GUI append on the emulator's thread and costs frames: it gets the opening lines and one in
-- twenty, the file gets every line.
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

local function slots_used()
	local n = 0
	for i = 0, NUM_OBJECT_STRUCTS - 1 do
		local s = u8(OBJECT_STRUCTS + (i * OBJECT_LENGTH))
		if s and s ~= 0 then
			n = n + 1
		end
	end
	return n
end

local function map_objects_used()
	local n = 0
	for i = 0, NUM_MAP_OBJECTS - 1 do
		local s = u8(MAP_OBJECTS + (i * MAPOBJECT_LENGTH) + M_SPRITE)
		if s and s ~= 0 then
			n = n + 1
		end
	end
	return n
end

-- The gate under test, logged at every change. Not wMapEventStatus or wScriptRunning: both toggle on every walking
-- step. wBattleMode is its own term because wMapStatus stays HANDLE through a battle.
local function would_spawn(v)
	return v.wMapStatus == 2 -- MAPSTATUS_HANDLE: the world exists and is stable
		and v.wBattleMode == 0 -- not in a wild or trainer battle
		and not (v.wMapGroup == 0 and v.wMapNumber == 0)
		and v.slots > 0 -- the player object exists
end

open_log()
log("=== MeshGhost Crystal in-game gate probe (READ-ONLY) ===")
log("Prints only on change. Start on the MAIN MENU, then load a save and play.")
log("The 'gate' column is what a spawn guard would decide at that moment.")

local last = nil
local frames = 0

local function tick()
	frames = frames + 1
	if frames % 5 ~= 0 then
		return
	end

	local v = { slots = slots_used(), mapobjs = map_objects_used() }
	for _, w in ipairs(WATCH) do
		v[w.name] = u8(w.addr)
	end

	-- Not keyed on wMapEventStatus/wScriptRunning, which toggle every step; they are still printed.
	local key = string.format(
		"%s|%s|%s/%s|%d|%d",
		tostring(v.wMapStatus), tostring(v.wBattleMode),
		tostring(v.wMapGroup), tostring(v.wMapNumber), v.slots, v.mapobjs
	)
	if key == last then
		return
	end
	last = key

	local gate = would_spawn(v) and "SPAWN-OK" or "blocked "
	log(string.format(
		"[%s] f=%-7d mapStatus=%-6s battle=%-7s map=%s/%s structs=%2d mapObjs=%2d  (events=%s script=%s paused=%s)",
		gate, frames,
		MAPSTATUS[v.wMapStatus] or tostring(v.wMapStatus),
		BATTLE[v.wBattleMode] or tostring(v.wBattleMode),
		tostring(v.wMapGroup), tostring(v.wMapNumber),
		v.slots, v.mapobjs,
		tostring(v.wMapEventStatus), tostring(v.wScriptRunning), tostring(v.wGameLogicPaused)
	))
end

while true do
	tick()
	emu.frameadvance()
end
