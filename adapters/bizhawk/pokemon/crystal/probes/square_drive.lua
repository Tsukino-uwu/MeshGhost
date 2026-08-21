-- MeshGhost — Pokémon Crystal: walk the player in a square, forever
--
-- DEVELOPMENT TOOL. It presses the d-pad; it writes no memory and reads none. `playing.md` allows
-- driving a running game to reach a state, and this is the cheapest version of that: a repeatable
-- movement pattern that costs nobody's attention.
--
-- WHY THIS EXISTS
-- The user's own test case, 2026-08-21: *"3x3 square, up/left/down/right. use this as a test
-- script"* -- given while chasing a ghost that *"went all the way up/down and off the screen
-- sometimes"*. An intermittent fault needs the same movement repeated many times, and a person
-- holding the controller for twenty minutes to reproduce it is the wrong tool for that.
--
-- Two sides of every square are vertical and two horizontal, so one lap exercises all four
-- directions, all four turns, and the corner case where a step is immediately followed by a turn.
-- Run it beside orphan_probe.lua and posediff_probe.lua and let it lap.
--
-- WHAT IT DOES NOT DO
-- It does not know where walls are. Point the player at open ground before starting it; if a side
-- is blocked the player bumps and the lap is still a valid test, it just covers less ground. It
-- never presses A or B, so it cannot talk to anyone, open a menu, or advance a script.
--
-- HOW TO RUN
--   Add it to dev-scripts/bizhawk-dev-loader-crystal.target; remove the line to stop it. It
--   announces each lap in the Lua Console and to square_drive_<timestamp>.log beside this file.
--   To stand still without unloading it, set the global MESHGHOST_SQUARE_PAUSE = true.

local SIDE = 3 -- tiles per side; the user's 3x3
local HOLD_FRAMES = 18 -- a normal step is 8 frames of movement; this leaves room for the turn
local DIRECTIONS = { "Up", "Left", "Down", "Right" }

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/square_drive_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end

local raw_log = console.log
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
	end
end

open_log()
log(string.format("=== MeshGhost Crystal square driver === %d tiles a side, %s",
	SIDE, table.concat(DIRECTIONS, " -> ")))
log("It only presses the d-pad. Set MESHGHOST_SQUARE_PAUSE = true to stand still.")

local dirIndex, tilesDone, heldFor, laps, frames = 1, 0, 0, 0, 0

local function tick()
	frames = frames + 1
	if MESHGHOST_SQUARE_PAUSE then
		return
	end

	-- Set with AND without the controller index: BizHawk's per-core controller naming differs, and
	-- a set that names a controller the core does not have is silently ignored rather than an
	-- error -- which reads exactly like "the script is running and the character will not move".
	local want = DIRECTIONS[dirIndex]
	pcall(joypad.set, { [want] = true })
	pcall(joypad.set, { [want] = true }, 1)
	heldFor = heldFor + 1

	-- READ BACK what the emulator thinks is held, rather than trusting the call above (CLAUDE.md:
	-- never log the value you just wrote as proof it worked). Once a second is enough to tell
	-- "the press is not registering" from "the press registers and the game is refusing to move".
	if frames % 60 == 0 then
		local ok, held = pcall(joypad.get)
		local names = {}
		if ok and type(held) == "table" then
			for k, v in pairs(held) do
				if v == true then names[#names + 1] = tostring(k) end
			end
		end
		table.sort(names)
		log(string.format("  pressing %-5s -- emulator reports held: %s", want,
			(#names > 0) and table.concat(names, "+") or "(nothing)"))
	end
	if heldFor < HOLD_FRAMES then
		return
	end

	heldFor = 0
	tilesDone = tilesDone + 1
	if tilesDone < SIDE then
		return
	end

	tilesDone = 0
	dirIndex = dirIndex + 1
	if dirIndex <= #DIRECTIONS then
		return
	end

	dirIndex = 1
	laps = laps + 1
	log(string.format("  lap %d complete", laps))
end

MESHGHOST_DEV_TICK = tick

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
		emu.frameadvance()
	end
end
