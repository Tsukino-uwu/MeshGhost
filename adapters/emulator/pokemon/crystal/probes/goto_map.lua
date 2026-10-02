-- Pokémon Crystal: warps the player to a named map, the way the game's own `warp` script command does. Writes RAM,
-- never the .sav, and savestates first to MESHGHOST_GOTO_UNDO_SLOT (default 8) as the undo.
-- It writes wMapGroup/wMapNumber directly (not wNext*), wXCoord/wYCoord, wDefaultSpawnpoint = SPAWN_N_A,
-- hMapEntryMethod = MAPSETUP_WARP and wMapStatus = MAPSTATUS_ENTER; without hMapEntryMethod the game re-enters the
-- current map. Set MESHGHOST_GOTO (a DESTINATIONS name, else DEFAULT) or MESHGHOST_GOTO_GROUP/_NUMBER/_WARP first;
-- it warps once and reads the map bytes back to report where it landed.

local DEFAULT = "lighthouse"

-- Group and map ids from our hash-verified build's map constants. Counting newgroup lines comes out 2 high (the macro
-- and a comment count too): any re-derivation must reproduce New Bark Town at group 24 and Route 40 at 22:1.
local DESTINATIONS = {
	-- Coordinates are wXCoord/wYCoord values; a silly landing means adjusting them, not a broken warp.
	lighthouse = { group = 3, number = 42, x = 9, y = 9, label = "Olivine Lighthouse 1F" },
	olivine = { group = 1, number = 14, x = 20, y = 20, label = "Olivine City" },
	-- 8,26 was picked clear of every trainer's line of sight, from the map's object list.
	route39 = { group = 1, number = 13, x = 8, y = 26, label = "Route 39 (crowd benchmark)" },
	-- 6,19 was picked two tiles clear of the Route 44 warp in the map's data: a warp tile bounces you back out.
	icepath = { group = 3, number = 61, x = 6, y = 19, label = "Ice Path 1F (ice tiles)" },
	icepathb1 = { group = 3, number = 62, x = 6, y = 19, label = "Ice Path B1F (the slide puzzle)" },
	-- Picked two tiles clear of the Ice Path door in the map's data, so arriving does not warp straight back in.
	blackthorn = { group = 5, number = 10, x = 34, y = 11,
		label = "Blackthorn City (outside the Ice Path door)" },
	-- Picked one tile below the Pokecenter door in the map's data: off the warp tile and clear of its objects.
	violet = { group = 10, number = 5, x = 31, y = 26,
		label = "Violet City (outside the Pokecenter)" },
}

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Addresses from our build's .sym.
local W_MAPSTATUS = flat(0xD432) -- wMapStatus, the same address the adapter uses
local W_MAPGROUP = flat(0xDCB5) -- wMapGroup
local W_MAPNUMBER = flat(0xDCB6) -- wMapNumber
local W_YCOORD = flat(0xDCB7) -- wYCoord
local W_XCOORD = flat(0xDCB8) -- wXCoord
local W_DEFAULTSPAWN = flat(0xD001) -- wDefaultSpawnpoint
local H_MAPENTRYMETHOD = 0xFF9F -- hMapEntryMethod, HRAM: reached on the System Bus, not WRAM
local MAPSTATUS_ENTER, MAPSTATUS_HANDLE = 1, 2
local MAPSETUP_WARP = 0xF1
local SPAWN_N_A = 0xFF -- -1

-- Overridable: other slots may hold prepared states, so saving over one is a choice. Slot 1 is never the agent's.
local UNDO_SLOT = tonumber(MESHGHOST_GOTO_UNDO_SLOT) or 8

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/goto_map_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, never flushed per line: a console line plus a flush stalls the emulator's thread for frames.
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- The console gets the first lines and one in twenty; the file gets every line.
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
		-- Flushed every 20 lines: bounded cost, and a live log (an unflushed one reads as nothing happened).
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

local function w8(addr, value)
	pcall(memory.write_u8, addr, value & 0xFF, DOMAIN)
end

local target = DESTINATIONS[MESHGHOST_GOTO or DEFAULT]
if MESHGHOST_GOTO_GROUP and MESHGHOST_GOTO_NUMBER then
	target = { group = MESHGHOST_GOTO_GROUP, number = MESHGHOST_GOTO_NUMBER,
		warp = MESHGHOST_GOTO_WARP or 1, label = "a map given by number" }
end

open_log()
log("=== MeshGhost Crystal goto (THIS ONE MOVES THE PLAYER) ===")

local done, waited = false, 0

local function tick()
	if done then
		return
	end
	if not target then
		log("No such destination. Set MESHGHOST_GOTO to one of: lighthouse, olivine, route39 "
			.. "-- or MESHGHOST_GOTO_GROUP/_NUMBER for a raw map id.")
		done = true
		return
	end

	-- Only from the settled overworld: warping out of a menu, a battle or a half-built map corrupts a session.
	if u8(W_MAPSTATUS) ~= MAPSTATUS_HANDLE then
		waited = waited + 1
		if waited % 180 == 0 then
			log("  waiting for the overworld -- close any menu and stand still for a moment.")
		end
		return
	end

	done = true
	local fromGroup, fromNumber = u8(W_MAPGROUP), u8(W_MAPNUMBER)

	-- The undo, before anything is written.
	local ok = pcall(savestate.saveslot, UNDO_SLOT)
	log(string.format("  saved slot %d as the undo%s. Load it to come straight back to %s/%s.",
		UNDO_SLOT, ok and "" or " (SAVE FAILED -- there is no undo)",
		tostring(fromGroup), tostring(fromNumber)))

	log(string.format("  going to %s (group %d, map %d, at %d,%d)",
		target.label, target.group, target.number, target.x, target.y))

	w8(W_MAPGROUP, target.group)
	w8(W_MAPNUMBER, target.number)
	w8(W_XCOORD, target.x)
	w8(W_YCOORD, target.y)
	w8(W_DEFAULTSPAWN, SPAWN_N_A)
	pcall(memory.write_u8, H_MAPENTRYMETHOD, MAPSETUP_WARP, "System Bus")
	w8(W_MAPSTATUS, MAPSTATUS_ENTER)
end

-- Reports where the player actually landed, from the map bytes, so a warp that did nothing can't read as success.
local reported = false
local settle = 0

local function report()
	if not done or reported or not target then
		return
	end
	settle = settle + 1
	if settle < 120 then
		return
	end
	reported = true
	local g, n = u8(W_MAPGROUP), u8(W_MAPNUMBER)
	if g == target.group and n == target.number then
		log(string.format("  arrived: the game reports group %d, map %d.", g, n))
	else
		log(string.format("  DID NOT ARRIVE: the game reports group %s, map %s, not %d/%d. "
			.. "Load slot %d and try a different warp number.",
			tostring(g), tostring(n), target.group, target.number, UNDO_SLOT))
	end
end

MESHGHOST_DEV_TICK = function()
	tick()
	report()
end

MESHGHOST_DEV_UNLOAD = function()
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end

-- A registered callback outlives its script under BizHawk, hence a loop rather than event.onframeend.
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		report()
		emu.frameadvance()
	end
end
