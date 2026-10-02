-- Pokémon Crystal: walks the player in a square forever, for intermittent faults that need the same movement many
-- times; one lap covers all four directions and turns. Presses the d-pad only (never A or B), reads and writes no
-- memory, and knows no walls: a blocked side bumps and still counts. Pause with MESHGHOST_SQUARE_PAUSE = true.

-- Tiles per side and the order of sides are options: a fault can be invisible over one tile and obvious over five.
local SIDE = tonumber(MESHGHOST_SQUARE_SIDE) or 2
local HOLD_FRAMES = 18 -- a walking step is about 16 video frames; this leaves room for the turn
local DIRECTIONS = MESHGHOST_SQUARE_DIRS or { "Up", "Left", "Down", "Right" }

-- Optionally start from a savestate, so a long walk begins on the same tile every run. It announces itself: the
-- global survives a loader reload and fires on every re-attach.
if MESHGHOST_SQUARE_LOAD_STATE then
	local slot = tonumber(MESHGHOST_SQUARE_LOAD_STATE)
	console.log(string.format("square_drive: LOADING SAVESTATE SLOT %s before starting -- "
		.. "MESHGHOST_SQUARE_LOAD_STATE is set. Set it to nil if you did not mean this; it "
		.. "survives a loader reload and fires on EVERY re-attach.", tostring(slot)))
	local ok, err = pcall(function() savestate.loadslot(slot) end)
	if not ok then
		console.log("square_drive: the savestate load FAILED: " .. tostring(err))
	end
end

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/square_drive_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
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

open_log()
log(string.format("=== MeshGhost Crystal square driver === %d tiles a side, %s",
	SIDE, table.concat(DIRECTIONS, " -> ")))
log("It only presses the d-pad. Set MESHGHOST_SQUARE_PAUSE = true to stand still.")

local dirIndex, tilesDone, heldFor, laps, frames = 1, 0, 0, 0, 0

-- Stop-and-go: pauses exercise what a steady walk never touches, the resume and the last step before a stop, where
-- snaps live. Fixed, not random, so a fault recurs on the same lap: every third side pauses 2s, and every lap 7s.
local pauseFor = 0

local function tick()
	frames = frames + 1
	if MESHGHOST_SQUARE_PAUSE then
		return
	end
	if pauseFor > 0 then
		pauseFor = pauseFor - 1
		return
	end

	-- Set with and without the controller index: a set naming a controller the core lacks is silently ignored.
	local want = DIRECTIONS[dirIndex]
	pcall(joypad.set, { [want] = true })
	pcall(joypad.set, { [want] = true }, 1)
	heldFor = heldFor + 1

	-- Read back what the emulator thinks is held, once a second: a press not registering is not the game refusing.
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
		-- MESHGHOST_SQUARE_FLOW: no stop inside the lap. With pauses each corner is a real stop and start, and a
		-- faithful ghost's catch-up there looks like a renderer fault.
		if not MESHGHOST_SQUARE_FLOW and dirIndex % 3 == 0 then
			pauseFor = 120 -- 2s: a stop-and-go inside the lap, below the idle-release threshold
			log(string.format("  pausing 2s after side %d", dirIndex - 1))
		end
		return
	end

	dirIndex = 1
	laps = laps + 1
	pauseFor = 420 -- 7s, short of the adapter's one-minute idle release
	log(string.format("  lap %d complete -- pausing 7s (crosses the idle release)", laps))
end

MESHGHOST_DEV_TICK = tick

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
		emu.frameadvance()
	end
end
