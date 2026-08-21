-- MeshGhost — Pokémon Crystal: what is true while a door transition is on screen?
--
-- READ-ONLY. No writes, no drawing.
--
-- WHY THIS EXISTS
-- The user, 2026-08-21: *"the drawn ghost is being shown when going in/out of houses"*. The painted
-- tier already carries the positive gate pitfalls.md asks for -- inPlay(), at least one live
-- hardware sprite, and the player's own four OAM entries present -- and a door transition slips
-- through all three. Something else has to say "the overworld is not really on screen", and the way
-- to find it is to watch every candidate ACROSS a transition rather than to reason about which
-- ought to work.
--
-- Emerald solved its version of this by matching the LIGHTING rather than by hiding: it compares
-- the live OBJ palette against the ROM palette the pixels were decoded from, so the painted copy
-- dims with every fade. Crystal's tier already reads wOBPals1 live each frame, so if a door fade
-- goes through that shadow the ghost should dim by itself -- and if it does not, that is the
-- finding, and this probe is what shows it.
--
-- WHAT IT LOGS, once per frame, but only when something changed:
--   wMapStatus, wStateFlags, wBattleMode      -- the state gate's own terms
--   live OAM sprites, and the player's 0-3    -- the "is anything being drawn" terms
--   OBJ palette brightness (channel sum)      -- how dark the scene actually is
--
-- Read it by finding the frames where the screen is plainly mid-transition and asking which column
-- ALREADY says so. That column is the missing gate term.
--
-- HOW TO RUN
--   Stand outside a house, walk in, walk out, repeat a few times. Log: transition_<timestamp>.log
--   beside this file. No timing to hit.

local DOMAIN = "WRAM"

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- Vanilla V1.0, the adapter's own vanilla table.
local W_MAPSTATUS = flat(0xD432)
local W_BATTLEMODE = flat(0xD22D)
local W_STATEFLAGS = flat(0xD0ED)
local W_MAPGROUP, W_MAPNUMBER = flat(0xDCB5), flat(0xDCB6)
local W_OBPALS = 0x5040 -- wOBPals1, WRAM bank 5 in this domain's flat layout

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/transition_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

local rawConsole, consoleLines = console.log, 0
local function log(msg)
	consoleLines = consoleLines + 1
	if consoleLines <= 4 or consoleLines % 20 == 0 then
		rawConsole(msg)
	end
	if logfile then
		logfile:write(msg, "\n")
	end
end

local function u8(a)
	local ok, v = pcall(memory.read_u8, a, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

open_log()
log("=== MeshGhost Crystal transition watch (READ-ONLY) ===")
log("Walk into a house and out again a few times. Prints only frames where something changed.")
log("The missing gate term is whichever column already says 'not the overworld' while the")
log("painted ghost is still visible.")

local frames, prev = 0, {}

local function tick()
	frames = frames + 1

	local live, playerEntries = 0, 0
	for i = 0, 39 do
		local y = memory.read_u8(i * 4, "OAM") or 0
		if y > 0 and y < 160 then
			live = live + 1
			if i < 4 then
				playerEntries = playerEntries + 1
			end
		end
	end

	-- Brightness of the palette the painted tier actually draws with. A fade to black or white
	-- moves this a long way, and it is the term Emerald ended up using.
	local sum = 0
	for i = 1, 3 do
		local lo = u8(W_OBPALS + i * 2) or 0
		local hi = u8(W_OBPALS + i * 2 + 1) or 0
		local c = lo | (hi << 8)
		sum = sum + (c & 0x1F) + ((c >> 5) & 0x1F) + ((c >> 10) & 0x1F)
	end

	local now = {
		status = u8(W_MAPSTATUS), battle = u8(W_BATTLEMODE), flags = u8(W_STATEFLAGS),
		map = string.format("%s/%s", tostring(u8(W_MAPGROUP)), tostring(u8(W_MAPNUMBER))),
		live = live, player = playerEntries, bright = sum,
	}

	local changed = false
	for k, v in pairs(now) do
		if prev[k] ~= v then
			changed = true
			break
		end
	end
	if changed then
		log(string.format("  f=%-7d map=%-7s status=%-4s battle=%-4s stateFlags=%-4s "
			.. "liveOAM=%-3d player0-3=%d objBrightness=%d",
			frames, now.map, tostring(now.status), tostring(now.battle), tostring(now.flags),
			now.live, now.player, now.bright))
		prev = now
	end

	if logfile and frames % 300 == 0 then
		pcall(function() logfile:flush() end)
	end
end

MESHGHOST_DEV_TICK = tick

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
		emu.frameadvance()
	end
end
