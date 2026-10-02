-- Pokémon Crystal/Archipelago: finds wPlayerState (on foot, bike, surf, running) by reversal. Read-only.
-- The address is the byte that changes on a bike toggle and changes back on the toggle back, so either starting state
-- works. Stay as you are 10s, toggle the bike 15s, toggle back 15s, as prompted; walking meanwhile filters out noise.

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
	-- Both halves are required: a byte that merely differs is a timer, a coordinate or an animation counter.
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
		-- Vanilla's states are 0 on foot and a power of two each; flagged, never required: a patch may renumber them.
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
