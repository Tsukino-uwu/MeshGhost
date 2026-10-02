-- Walks, stands still past the adapter's idle rule, walks again, forever: one demote/promote pair a cycle without
-- anyone holding a controller. Presses only the d-pad and reads the player's tile to check its input landed; writes
-- nothing. Run it on the instance you are not watching: the fault shows on the client watching this peer. It does
-- not know where walls are, so point the player at open ground. MESHGHOST_IDLE_CYCLE_PAUSE = true stands still.

local WALK_FRAMES = 60 -- 1s, four tiles: inside the 8-tile range cull, whose despawns would pass for the idle rule's
-- Above the adapter's IDLE_FRAMES_BEFORE_PASSABLE, or no demote happens: lower both together, never this alone.
local REST_FRAMES = 4200 -- 70s, comfortably past the adapter's 3600-frame idle rule.
local DIRECTIONS = MESHGHOST_IDLE_CYCLE_DIRS or { "Left", "Right" }

-- The game's own tile, not joypad.get, is the evidence the input landed; by ROM title, as Archipelago moves the array.
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
		pcall(function() logfile:flush() end) -- one line a phase, never a frame
	end
end

say("=== MeshGhost Crystal idle/move cycle driver (d-pad only) ===")
say(string.format("walk %d frames, rest %d frames (the adapter's idle rule is 300), directions: %s",
	WALK_FRAMES, REST_FRAMES, table.concat(DIRECTIONS, "/")))
say("Watch the OTHER client. Set MESHGHOST_IDLE_CYCLE_PAUSE = true to stand still.")

local frames, phase, dirIx, cycle = 0, "walk", 1, 0
-- A local, so a reload re-reads the tile instead of comparing against a stale global.
local walkFromX, walkFromY = playerTile()

local function tick()
	if MESHGHOST_IDLE_CYCLE_PAUSE then
		return
	end
	frames = frames + 1

	if phase == "walk" then
		-- Held every frame (a tap turns without moving). Both call shapes, each in a pcall: an ignored input
		-- call raises nothing, and the run would silently test nothing.
		local want = DIRECTIONS[dirIx]
		pcall(joypad.set, { [want] = true })
		pcall(joypad.set, { [want] = true }, 1)
		if frames >= WALK_FRAMES then
			frames, phase = 0, "rest"
			-- Alternate, so a long session does not walk the player off into somewhere with no room.
			dirIx = (dirIx % #DIRECTIONS) + 1
			cycle = cycle + 1
			-- The game's own tile, start against end: ignored input would log a perfect-looking cycle forever.
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
