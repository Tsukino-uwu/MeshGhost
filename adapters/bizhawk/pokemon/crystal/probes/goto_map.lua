-- MeshGhost — Pokémon Crystal: warp the player to a named map (DEV TOOL, WRITES)
--
-- **THIS ONE MOVES THE PLAYER**, on request. `playing.md` allows driving a running game to reach a
-- state, and reaching a test location on foot costs the user's time rather than mine. It never
-- writes the .sav.
--
-- IT SAVES TO SLOT 8 FIRST, ALWAYS. Slot 8 is this project's convention for "the undo for a warp"
-- -- load it to get back exactly where you were. A savestate is not an in-game save.
--
-- HOW IT WORKS, and every step is the game's own
-- `EnterMapWarp` (engine/overworld/warp_connection.asm) copies wNextWarp / wNextMapGroup /
-- wNextMapNumber into wWarpNumber / wMapGroup / wMapNumber when the map-status machine passes
-- through MAPSTATUS_ENTER. So a warp is: name the destination in those three bytes, then put the
-- machine into ENTER and let the game do everything else -- loading the map, placing the player at
-- that map's warp, rebuilding the object arrays. Nothing here writes a coordinate or a tile.
--
-- WHICH WARP. Warp 1 is a map's first warp event, which for a building is its front door and for a
-- route is one end of it. If a destination lands somewhere odd, try another warp number rather
-- than writing coordinates by hand -- the warp table is the game's own list of legitimate places
-- to stand.
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
local DESTINATIONS = {
	lighthouse = { group = 3, number = 42, warp = 1, label = "Olivine Lighthouse 1F" },
	olivine = { group = 1, number = 14, warp = 1, label = "Olivine City" },
	-- The user, 2026-08-21: the route above Olivine is *"the most demanding one in the whole
	-- game... a big route, and fills up things due to having a lot of npc's"*. Recorded as the
	-- reason it is in this list -- it is the crowd benchmark, not a scenic stop. Treat the claim as
	-- a hint to verify with a measurement, not as a fact about the game.
	route39 = { group = 1, number = 13, warp = 1, label = "Route 39 (crowd benchmark)" },
}

local DOMAIN = "WRAM"

local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- pokecrystal.sym
local W_NEXTWARP = flat(0xD146) -- wNextWarp
local W_NEXTMAPGROUP = flat(0xD147) -- wNextMapGroup
local W_NEXTMAPNUMBER = flat(0xD148) -- wNextMapNumber
local W_MAPSTATUS = flat(0xD432) -- wMapStatus, the same address the adapter uses
local W_MAPGROUP = flat(0xDCB5) -- wMapGroup
local W_MAPNUMBER = flat(0xDCB6) -- wMapNumber
local MAPSTATUS_ENTER, MAPSTATUS_HANDLE = 1, 2

local UNDO_SLOT = 8

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/goto_map_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
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

	log(string.format("  going to %s (group %d, map %d, warp %d)",
		target.label, target.group, target.number, target.warp))

	w8(W_NEXTWARP, target.warp)
	w8(W_NEXTMAPGROUP, target.group)
	w8(W_NEXTMAPNUMBER, target.number)
	-- Hand the map-status machine to ENTER and let the game load the map itself.
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
