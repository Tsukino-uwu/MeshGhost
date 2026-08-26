-- MeshGhost — Pokémon Crystal: warp the player to a named map (DEV TOOL, WRITES)
--
-- **THIS ONE MOVES THE PLAYER**, on request. `playing.md` allows driving a running game to reach a
-- state, and reaching a test location on foot costs the user's time rather than mine. It never
-- writes the .sav.
--
-- IT SAVES TO SLOT 8 FIRST, ALWAYS. Slot 8 is this project's convention for "the undo for a warp"
-- -- load it to get back exactly where you were. A savestate is not an in-game save.
--
-- HOW IT WORKS: exactly what the GAME'S OWN `warp` script command does, in the same order.
-- `Script_warp` (engine/overworld/scripting.asm:2060) is six writes and nothing else:
--
--   wMapGroup, wMapNumber        -- the destination map, written DIRECTLY (not via wNext*)
--   wXCoord, wYCoord             -- where to stand on it
--   wDefaultSpawnpoint = -1      -- SPAWN_N_A, "no respawn point implied by this warp"
--   hMapEntryMethod = $f1        -- MAPSETUP_WARP: WHICH setup script the map machine runs
--   wMapStatus = MAPSTATUS_ENTER -- LoadMapStatus (home/map.asm:921) is just this store
--
-- THE ONE THAT MATTERS, and the one whose absence broke the first version of this file on
-- 2026-08-21: **hMapEntryMethod**. `EnterMapWarp` is a map SETUP SCRIPT (entry 19 of
-- MapSetupCommands), not something the status byte runs by itself -- so setting only wMapStatus
-- made the game re-enter the map it was already on and consume no destination at all. The user saw
-- it as *"it just glitched my current map"*. The read-back below is why that was caught rather
-- than believed.
--
-- HOW TO RUN
--   Set the destination before loading it, either as globals or by editing DEFAULT below:
--     MESHGHOST_GOTO = "route39"     -- a name from DESTINATIONS
--     MESHGHOST_GOTO_GROUP, MESHGHOST_GOTO_NUMBER, MESHGHOST_GOTO_WARP  -- or raw ids
--   Add it to the loader's target file. It warps ONCE, reports where it actually landed by reading
--   the map bytes back, and then does nothing. Log: goto_map_<timestamp>.log beside this file.

local DEFAULT = "lighthouse"

-- Group and map numbers from constants/map_constants.asm in our own hash-verified pokecrystal
-- build. The group is the newgroup block the map_const sits in; the number is the value the file
-- prints beside it.
-- GROUP NUMBERS ARE VERIFIED AGAINST A CONTROL, and the three entries below were WRONG once.
-- `constants/map_constants.asm` annotates each `newgroup` with its index, but counting newgroup
-- LINES also counts the `MACRO newgroup` definition and a comment mentioning it -- so a derived
-- count comes out +2 and every id is silently plausible. Live cost, 2026-08-26: Ice Path went in
-- as 5:61 and Blackthorn as 7:10, which warped the user into an unrelated dark map and then into
-- what they recognised as the Rocket hideout. Nothing errored; the warp worked perfectly, at the
-- wrong map.
-- The controls that settle it: NEW_BARK_TOWN must be group 24 (`documentation.md` says so
-- independently) and ROUTE_40 must be 22:1 (read live from a running game by `trainer_check.lua`).
-- Any re-derivation of these numbers has to reproduce BOTH before it is trusted.
local DESTINATIONS = {
	-- Coordinates are in the game's own map-tile space, the same numbers wXCoord/wYCoord hold while
	-- standing there. Each map's usable area starts a few tiles in from 0, so these are picked
	-- toward the middle; if one lands somewhere silly, load slot 8 and adjust rather than assuming
	-- the warp is broken.
	lighthouse = { group = 3, number = 42, x = 9, y = 9, label = "Olivine Lighthouse 1F" },
	olivine = { group = 1, number = 14, x = 20, y = 20, label = "Olivine City" },
	-- The user, 2026-08-21: the route above Olivine is *"the most demanding one in the whole
	-- game... a big route, and fills up things due to having a lot of npc's"*. Recorded as the
	-- reason it is in this list -- it is the crowd benchmark, not a scenic stop. Treat the claim as
	-- a hint to verify with a measurement, not as a fact about the game.
	-- 10,20 was a BAD choice and cost the user a trainer battle on arrival, 2026-08-21: the Pokefan
	-- at 10,22 faces UP with a sight range of 4, so 10,20 is two tiles inside its line. Route 39's
	-- trainers, from maps/Route39.asm's own object_events -- position, facing, range:
	--     10,22 up 4  |  11,19 right 4  |  13,29 left 5  |  13,7 spin 1
	-- 8,26 sits outside every one of those lines: wrong column for the two northern ones, seven
	-- tiles north of the sailor's row, nowhere near the spinner.
	route39 = { group = 1, number = 13, x = 8, y = 26, label = "Route 39 (crowd benchmark)" },
	-- ICE. The reason this entry exists is the one movement class this adapter has never tested:
	-- an ice tile forces `STEP_ICE` (`engine/overworld/player_movement.asm`), which slides a
	-- character across tiles it did not ask to cross. `_template/README.md` has the general
	-- warning as "a movement that does not animate is still a movement" -- Emerald's ice slides a
	-- character with its legs still, and a ghost driven from position alone walks where the player
	-- glides.
	-- 6,19 rather than the warp tile itself: `maps/IcePath1F.asm`'s Route 44 warp is at 4,19, and
	-- landing ON a warp tile is how you get bounced straight back out. The other three warps on
	-- this floor (36,27 to Blackthorn, 37,5 and 37,13 down to B1F) are all far from here.
	icepath = { group = 3, number = 61, x = 6, y = 19, label = "Ice Path 1F (ice tiles)" },
	icepathb1 = { group = 3, number = 62, x = 6, y = 19, label = "Ice Path B1F (the slide puzzle)" },
	-- OUTSIDE the Ice Path, two tiles clear of its entrance.
	-- `maps/BlackthornCity.asm:323` puts the Ice Path door at 36,9; 34,11 is clear of it, so
	-- arriving does not immediately warp back in.
	--
	-- A CORRECTION KEPT ON PURPOSE. The grey screen that prompted this entry was blamed on Ice
	-- Path being a dark cave with no FLASH -- `data/maps/maps.asm` does give it CAVE +
	-- PALETTE_NITE, and `warp_check.lua` did report "BG row 0 = ALL ONE TILE" with the player
	-- drawn, which fits that story exactly. It was wrong. The grey map was 5:61, an unrelated
	-- map reached with the off-by-two group id above; warping to the REAL Ice Path (3:61) renders
	-- it fully lit with `wStatusFlags` = 10, i.e. the FLASH bit CLEAR. Ice Path is not dark, and
	-- the Flash grant written for this was never needed.
	-- The lesson is `pitfalls.md`'s: a plausible mechanism that explains every symptom is not
	-- evidence, and the decompilation says what a map CAN be rather than what went wrong here.
	-- The control (New Bark = group 24) would have caught it before any of it was written.
	blackthorn = { group = 5, number = 10, x = 34, y = 11,
		label = "Blackthorn City (outside the Ice Path door)" },
}

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- pokecrystal.sym
local W_MAPSTATUS = flat(0xD432) -- wMapStatus, the same address the adapter uses
local W_MAPGROUP = flat(0xDCB5) -- wMapGroup
local W_MAPNUMBER = flat(0xDCB6) -- wMapNumber
local W_YCOORD = flat(0xDCB7) -- wYCoord
local W_XCOORD = flat(0xDCB8) -- wXCoord
local W_DEFAULTSPAWN = flat(0xD001) -- wDefaultSpawnpoint
local H_MAPENTRYMETHOD = 0xFF9F -- hMapEntryMethod, HRAM: reached on the System Bus, not WRAM
local MAPSTATUS_ENTER, MAPSTATUS_HANDLE = 1, 2
local MAPSETUP_WARP = 0xF1
local SPAWN_N_A = 0xFF -- SPAWN_N_A is -1 (constants/map_data_constants.asm:101)

-- OVERRIDABLE, because slot 8 stopped being free. It was this project's warp-undo convention
-- until 2026-08-26, when the user re-recorded 8 and 9 as the same-town and cross-town Fly states
-- (`agent_docs/status.md`). Saving over one of those costs a prepared state that took real time to
-- make, and the default here would do it silently on every warp. The user's position is that
-- overwriting is allowed when a slot is needed -- this exists so it is a CHOICE rather than a
-- side effect. Slots 2+ are the agent's; 1 is the user's on every instance (`playing.md`).
local UNDO_SLOT = tonumber(MESHGHOST_GOTO_UNDO_SLOT) or 8

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/goto_map_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
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

	-- Only from the overworld with the map machine settled: warping out of a menu, a battle or a
	-- half-built map is how a session gets corrupted rather than moved.
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

-- Report where the player ACTUALLY ended up, read from the map bytes rather than from the
-- destination we asked for -- a warp that silently did nothing would otherwise read as a success.
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

-- A registered callback outlives its script under BizHawk, which is why this is a loop and not
-- event.onframeend (pitfalls.md).
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		report()
		emu.frameadvance()
	end
end
