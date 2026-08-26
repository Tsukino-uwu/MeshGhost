-- MeshGhost — Pokémon Crystal: walk, stand still past the idle rule, walk again. Forever.
--
-- DEVELOPMENT TOOL. It presses the d-pad and nothing else: no memory reads, no writes, no A or B,
-- so it cannot talk to anyone, open a menu or advance a script. `playing.md` allows driving a
-- running game to reach a state; this reaches one *repeatedly*.
--
-- WHY THIS EXISTS
-- `square_drive.lua` walks a square and never stops, and the fault this was written for lives in
-- the STOPPING. The user, 2026-08-26: a third, static character appears *"whenever you move after
-- the despawn/respawn"*, and *"its related to the 5sec despawn/respawn thing, as that is what
-- triggers there being a orphan"*. So the reproduction is a cycle, not a lap:
--
--   walk a few tiles  ->  stand still LONGER THAN THE IDLE RULE  ->  walk again
--
-- The adapter's `IDLE_FRAMES_BEFORE_PASSABLE` is 300 frames (5s): a peer that has not changed tile
-- for that long stops blocking and is handed to the drawn tier, which despawns its engine object.
-- Moving again promotes it back and spawns a fresh one. That demote/promote pair is the event
-- under investigation, and this script produces one every ~15 seconds without anyone holding a
-- controller.
--
-- RUN IT ON THE *OTHER* MACHINE FROM THE ONE YOU ARE WATCHING. The orphan appears on the client
-- watching a PEER do this, so this drives instance A and the instrument runs on instance B. Both
-- at once works but confounds the two: leave one side still.
--
-- REST IS DELIBERATELY LONGER THAN THE RULE, not equal to it. 8 seconds against a 5-second rule
-- means a slow frame, a bump, or a step that lands late cannot leave the cycle short of the
-- threshold and quietly produce a run where the demote never happened -- which would look exactly
-- like the fault not reproducing. Probes ask for endurance, never for hitting a window.
--
-- HOW TO RUN
--   Add it to a dev loader target beside the adapter; remove the line to stop it. It logs every
--   phase change to idle_cycle_<timestamp>.log beside this file and to the Lua Console, so the
--   probe's own timestamps can be lined up against the cycle afterwards.
--   MESHGHOST_IDLE_CYCLE_PAUSE = true stands still without unloading it.
--
-- IT DOES NOT KNOW WHERE WALLS ARE. Point the player at open ground first. A blocked side bumps,
-- which is still a valid cycle -- the peer simply covers less ground -- but the walk phase then
-- reports no tile change, and the log says so rather than leaving it to be guessed.

local WALK_FRAMES = 60 -- 1s of held d-pad. DELIBERATELY SHORT OF THE RANGE CULL: the adapter
-- gives a peer's slots back past GHOST_RANGE_TILES (8), and the first version of this script held
-- the d-pad for 150 frames, which walks NINE tiles. Every cycle therefore crossed that boundary
-- and the log filled with despawn/respawn pairs that were the cull, not the idle rule -- the exact
-- transition under investigation, drowned in a different one that looks identical in a log.
-- Four tiles keeps the whole cycle inside the peer's range so the only despawn is the one meant.
local REST_FRAMES = 480 -- 8s, comfortably past the adapter's 300-frame idle rule.
local DIRECTIONS = MESHGHOST_IDLE_CYCLE_DIRS or { "Left", "Right" }

-- WHERE THE PLAYER ACTUALLY IS, so the driver can check its own input landed instead of assuming.
-- Reading back the GAME's position is independent evidence; reading back `joypad.get` would only
-- report what this script just set, which is the "log the value you just wrote" trap. Build
-- selected by the ROM header title, the same seed-independent signal the adapter uses -- the
-- Archipelago patch moves the object array, and a driver that read vanilla's addresses on it would
-- report "did not move" on every cycle of a run that was working perfectly.
local PLAYER = 0x14D6 -- vanilla V1.0, wObjectStructs flattened
do
	local t = {}
	for i = 0, 9 do
		local c = memory.read_u8(0x134 + i, "ROM")
		t[#t + 1] = c and string.char(c) or ""
	end
	if table.concat(t):sub(1, 3) == "AP_" then
		PLAYER = 0x14DC
	end
end
local F_MAP_X, F_MAP_Y = 0x10, 0x11

local function playerTile()
	local x = memory.read_u8(PLAYER + F_MAP_X, "WRAM")
	local y = memory.read_u8(PLAYER + F_MAP_Y, "WRAM")
	return x or -1, y or -1
end

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

local logfile = io.open(string.format("%s/idle_cycle_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function say(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		pcall(function() logfile:flush() end) -- one line per PHASE, not per frame: cost is nil
	end
end

say("=== MeshGhost Crystal idle/move cycle driver (d-pad only) ===")
say(string.format("walk %d frames, rest %d frames (the adapter's idle rule is 300), directions: %s",
	WALK_FRAMES, REST_FRAMES, table.concat(DIRECTIONS, "/")))
say("Watch the OTHER client. Set MESHGHOST_IDLE_CYCLE_PAUSE = true to stand still.")

local frames, phase, dirIx, cycle = 0, "walk", 1, 0
-- Where the current walk phase started, so its end can be compared against it. A bare global would
-- survive a reload and make the first cycle after one compare against a stale tile; a local here
-- is re-initialised with the script, which is what we want.
local walkFromX, walkFromY = playerTile()

local function tick()
	if MESHGHOST_IDLE_CYCLE_PAUSE then
		return
	end
	frames = frames + 1

	if phase == "walk" then
		-- Held every frame. A tap would turn the character without moving it, which is a
		-- different event entirely and not the one being reproduced.
		--
		-- BOTH CALL SHAPES, EACH IN A pcall -- copied from square_drive.lua, which is the version
		-- that has actually driven this game. Passing the controller index alone did nothing here
		-- (2026-08-26): the script ticked happily, logged five clean cycles, and the player never
		-- moved a pixel. An input call that is ignored does not raise -- it just silently produces
		-- a run where the thing under test never happened, which reads exactly like the fault
		-- failing to reproduce. Whichever shape this BizHawk build honours, one of these is it.
		local want = DIRECTIONS[dirIx]
		pcall(joypad.set, { [want] = true })
		pcall(joypad.set, { [want] = true }, 1)
		if frames >= WALK_FRAMES then
			frames, phase = 0, "rest"
			-- Alternate, so the cycle returns roughly to where it started and a long session does
			-- not walk the player off the map into somewhere with no room.
			dirIx = (dirIx % #DIRECTIONS) + 1
			cycle = cycle + 1
			-- DID THE WALK ACTUALLY WALK? The game's own tile, start against end. A driver whose
			-- input is being ignored logs a perfect-looking cycle forever and the run silently
			-- tests nothing -- which is what happened on the first attempt here.
			local ex, ey = playerTile()
			local moved = (ex ~= walkFromX or ey ~= walkFromY)
			say(string.format("[cycle %d] %s -- resting %d frames; the peer should go idle, stop "
				.. "blocking, and its engine object should be despawned",
				cycle,
				moved and string.format("walked %d,%d -> %d,%d", walkFromX, walkFromY, ex, ey)
					or string.format("*** DID NOT MOVE *** (still %d,%d -- input ignored, or "
						.. "walled in; this cycle tested nothing)", ex, ey),
				REST_FRAMES))
		end
	else
		if frames >= REST_FRAMES then
			frames, phase = 0, "walk"
			walkFromX, walkFromY = playerTile()
			say(string.format("[cycle %d] walking %s from %d,%d -- this is the PROMOTION; a third "
				.. "character appearing now is the fault",
				cycle, DIRECTIONS[dirIx], walkFromX, walkFromY))
		end
	end
end

MESHGHOST_DEV_UNLOAD = function()
	if logfile then
		pcall(function() logfile:close() end)
		logfile = nil
	end
end

if MESHGHOST_DEV_LOADER then
	MESHGHOST_DEV_TICK = tick
else
	while true do
		tick()
		emu.frameadvance()
	end
end
