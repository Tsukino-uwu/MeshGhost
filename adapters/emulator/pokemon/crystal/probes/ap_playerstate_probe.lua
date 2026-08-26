-- MeshGhost — Pokémon Crystal/Archipelago: find wPlayerState (on foot / bike / surf / running)
--
-- READ-ONLY. Writes nothing, presses nothing.
--
-- WHY THIS IS THE ADDRESS THAT UNBLOCKS TWO BUGS AT ONCE, both reported 2026-08-26:
--   * on the Archipelago client, a peer's ghost MIMICS the local player -- get on a bike and the
--     ghost mounts one too;
--   * on the vanilla client, an Archipelago peer is never shown mounting anything at all.
--
-- One cause. A peer's `extras.sprite` is an INDEX, and this build renumbers its tables, so the
-- `gfx` gate drops the id in a mixed room and the drawn tier falls back to "wear this machine's
-- own player sprite" -- read live, every frame. Mount a bike locally and the fallback follows.
--
-- The fix is the repo's own standing rule (`_template/README.md`, "Send the QUESTION, not the
-- engine's own byte"): put a PORTABLE STATE on the wire -- on foot, bike, surf, running -- and let
-- each receiver draw it with its own graphics, instead of shipping an index that means different
-- things on different cartridges. `wPlayerState` is where that state lives, and it has never been
-- measured on this build.
--
-- HOW -- reversal, which is this repo's most reliable finder (`probes.md`)
-- A state byte is not found by scanning for a shape; it is found by CHANGING it and watching. So:
-- stand on foot, get on the bike, get off again. The address is the byte that changed on the way
-- in and changed BACK on the way out -- and almost nothing else in WRAM does that on cue.
--
-- Vanilla's values are 0 on foot, 1 bike, 2 skate, 4 surf, 8 surfing Pikachu
-- (`constants/wram_constants.asm`), which is a bit-per-state layout, so the byte is small and its
-- values are powers of two. Reported, but NOT required: this build is free to number them
-- differently, and demanding vanilla's values is exactly the assumption that turned a bicycle into
-- a Moon Stone earlier today. Every byte that reverses is listed; the shortlist is a convenience.
--
-- HOW TO RUN -- about 45 seconds, nothing to time
--   1. Be in the overworld with the bike in your bag. EITHER STATE IS A FINE STARTING POINT --
--      the probe looks for a byte that changes and changes BACK, so which way round the toggle
--      goes does not matter. (Written that way on 2026-08-26 after two restarts spent trying to
--      get the player and the probe into the same starting state; a probe that needs the world
--      arranged around it wastes live cycles for nothing.)
--   2. Load it. PHASE 1 (10s) STAY AS YOU ARE -- it snapshots.
--   3. PHASE 2 (15s) TOGGLE the bike and stay in the new state.
--   4. PHASE 3 (15s) TOGGLE BACK and stay there.
--      Log: ap_playerstate_<timestamp>.log beside this file.
--
--   Walking around during the phases is fine and helps: a byte that changes because you MOVED will
--   not reverse cleanly, so motion actively filters out coordinate and timer noise.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000

local ON_FOOT_FRAMES = 600
local ON_BIKE_FRAMES = 900
local OFF_BIKE_FRAMES = 900

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

local logfile = io.open(string.format("%s/ap_playerstate_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function say(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		pcall(function() logfile:flush() end)
	end
end

local function snapshot()
	local t = {}
	for a = 0, WRAM_SIZE - 1 do
		t[a] = memory.read_u8(a, DOMAIN) or 0
	end
	return t
end

say("=== MeshGhost Crystal/AP wPlayerState probe (READ-ONLY) ===")
say("PHASE 1 (10s): STAY AS YOU ARE -- on foot or on the bike, it does not matter which.")

local foot, bike
local phase, frames = 1, 0

local function report()
	local now = snapshot()
	-- THE REVERSAL, and both halves are required. A byte that merely differs between two moments
	-- is noise -- a timer, a coordinate, an animation counter. The address wanted is the one that
	-- took a NEW value on the bike and RETURNED to its original when the bike was put away.
	local hits = {}
	for a = 0, WRAM_SIZE - 1 do
		if foot[a] ~= bike[a] and now[a] == foot[a] then
			hits[#hits + 1] = a
		end
	end
	say(string.format("=== RESULT: %d byte(s) changed on the toggle and changed BACK ===", #hits))
	local shortlist = {}
	for _, a in ipairs(hits) do
		local f, b = foot[a], bike[a]
		local line = string.format("  0x%04X (CPU $%04X)  phase1 %3d (%02X) -> phase2 %3d (%02X)",
			a, (a < 0x1000) and (0xC000 + a) or (0xD000 + a - 0x1000), f, f, b, b)
		-- Vanilla's wPlayerState is a bit-per-state byte: 0 on foot, 1 bike, 2 skate, 4 surf.
		-- So "0 while walking, a small power of two on the bike" is the shape to look at FIRST --
		-- flagged, never required, because this build may number its states differently.
		if (f == 0 or b == 0) and (f == 1 or b == 1 or f == 2 or b == 2 or f == 4 or b == 4
			or f == 8 or b == 8 or f == 16 or b == 16) then
			line = line .. "   <== SHAPE OF A STATE BYTE"
			shortlist[#shortlist + 1] = a
		end
		say(line)
	end
	if #hits == 0 then
		say("NOTHING REVERSED. Either the bike was not actually mounted and dismounted inside the")
		say("two phases, or this build keeps the state somewhere this probe did not look. Re-run")
		say("before concluding anything -- an empty result here is a failed run, not a finding.")
	elseif #shortlist == 1 then
		say(string.format("ONE candidate has the shape of a state byte: 0x%04X. Confirm it by "
			.. "watching it while SURFING too -- a state byte takes a different value for each "
			.. "state, and a byte that only knows about bikes is a bike flag, not the state.",
			shortlist[1]))
	else
		say("Confirm against a THIRD state (surf) before recording one: two states cannot tell a "
			.. "state byte from a bike flag, and this repo has already adopted a byte that fit "
			.. "two samples and failed the third (see W_MAPSTATUS in the adapter).")
	end
	if logfile then
		pcall(function() logfile:flush() end)
	end
end

local function tick()
	if phase > 3 then
		return
	end
	frames = frames + 1
	if phase == 1 and frames >= ON_FOOT_FRAMES then
		foot = snapshot()
		phase, frames = 2, 0
		say("PHASE 2 (15s): TOGGLE THE BIKE now -- mount if you are on foot, dismount if you are "
			.. "riding -- and stay in that state.")
	elseif phase == 2 and frames >= ON_BIKE_FRAMES then
		bike = snapshot()
		phase, frames = 3, 0
		say("PHASE 3 (15s): TOGGLE BACK now, and stay there.")
	elseif phase == 3 and frames >= OFF_BIKE_FRAMES then
		phase = 4
		report()
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
