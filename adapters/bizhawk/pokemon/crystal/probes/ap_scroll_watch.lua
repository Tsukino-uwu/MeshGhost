-- MeshGhost — Crystal/Archipelago: watch the scroll-offset neighbourhood directly
--
-- READ-ONLY. Writes nothing, spawns nothing.
--
-- WHY
-- The wide scan (ap_scroll_probe.lua) found 405 "Y" candidates and 2 "X" ones, and the Y list is
-- mostly the OAM shadow at 0x04xx — sprite positions, which scroll with the camera and are not
-- what screenCoords() wants. Its axis filter was too strict in the other direction too: it demanded
-- a byte NEVER move while standing, and anything the game nudges on its own (an NPC stepping, a
-- camera settle) is disqualified for the whole run.
--
-- One address survived in the right neighbourhood: 0x1154, with 190 changes. Vanilla keeps
-- wBGMapOffsetX/Y at 0xD14C/0xD14D — flat 0x114C/0x114D — so 0x1154 is vanilla+7, the same delta
-- the coordinate block moved, with 0x1153 as its X partner.
--
-- That is a hypothesis assembled from a delta, which is exactly the reasoning this build has
-- already refuted three times. So it gets watched rather than believed: this probe just prints the
-- whole neighbourhood as you walk, and the answer is whichever pair actually behaves like a scroll
-- offset — one axis each, cycling through a run of values within a step rather than flipping.
--
-- HOW TO RUN — 40 seconds, nothing to time
--   1. Load the ARCHIPELAGO Crystal ROM, stand in the overworld.
--   2. Lua Console -> Script -> Open, pick this file.
--   3. Walk LEFT and RIGHT for ~20 seconds, then UP and DOWN for ~20. The console says which
--      phase it is in; walking sloppily is fine, standing still for a moment is fine.
--      Log: ap_scrollwatch_<timestamp>.log beside this script.

local DOMAIN = "WRAM"
local SAMPLE_EVERY = 2 -- a scroll offset changes within a single step, so sample fast. The read
-- set is 14 bytes, not 32k, so this costs nothing (probes.md, read budget).

local FIRST = 0x114C
local LAST = 0x1159

local X, Y = 0x1CBF, 0x1CBE -- MEASURED (verified.md, 2026-08-18)

-- Riding along, because this run is free and the question is open: 0x0FB1 is being used as
-- wMapStatus and sits 0x481 BELOW vanilla's, while everything else measured on this build moved
-- by +7, +6 or -0x2A. Vanilla+7 would be 0x1439, which nothing has looked at yet. If 0x1439 holds
-- 2 steadily during normal play, it is the better candidate and 0x0FB1 was a lookalike.
local EXTRA = { 0x1439, 0x0FB1 }
local PHASE_FRAMES = 1200 -- 20 seconds per axis

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

local logfile = io.open(string.format("%s/ap_scrollwatch_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function log(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

local function say(msg)
	console.log(msg)
	log(msg)
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return 0
end

say("=== MeshGhost Crystal/AP scroll-offset watch (READ-ONLY) ===")
say("PHASE 1 (20s): walk LEFT and RIGHT.")

local header = {}
for a = FIRST, LAST do
	header[#header + 1] = string.format("%04X", a)
end
log("")
log("phase  x   y  | " .. table.concat(header, "  "))

-- Per address and per phase: how many distinct values it took, and how many changes. A scroll
-- offset takes MANY values on its own axis and none on the other; a flag takes two.
local seen = { {}, {} }
local changes = { {}, {} }
for a = FIRST, LAST do
	for p = 1, 2 do
		seen[p][a], changes[p][a] = {}, 0
	end
end

local prev = {}
for a = FIRST, LAST do
	prev[a] = u8(a)
end

local frames, phase = 0, 1

local function report()
	log("")
	say("=== RESULT ===")
	for a = FIRST, LAST do
		local counts = {}
		for p = 1, 2 do
			local n = 0
			for _ in pairs(seen[p][a]) do
				n = n + 1
			end
			counts[p] = n
		end
		local note = ""
		if counts[1] >= 6 and counts[2] <= 2 then
			note = "   <-- moves on LEFT/RIGHT only: candidate wBGMapOffsetX"
		elseif counts[2] >= 6 and counts[1] <= 2 then
			note = "   <-- moves on UP/DOWN only: candidate wBGMapOffsetY"
		elseif counts[1] >= 6 and counts[2] >= 6 then
			note = "   (moves on both axes: a camera or timer value, not a per-axis offset)"
		end
		local vals = {}
		for v in pairs(seen[1][a]) do
			vals[#vals + 1] = v
		end
		for v in pairs(seen[2][a]) do
			vals[#vals + 1] = v
		end
		table.sort(vals)
		local shown = {}
		for i = 1, math.min(#vals, 16) do
			shown[#shown + 1] = tostring(vals[i])
		end
		say(string.format("  0x%04X: %2d value(s) on X, %2d on Y  [%s]%s",
			a, counts[1], counts[2], table.concat(shown, " "), note))
	end
	for _, a in ipairs(EXTRA) do
		say(string.format("  context: 0x%04X reads %d right now (2 = normal play, if it is the "
			.. "status byte)", a, u8(a)))
	end
	say("The pair that screenCoords() wants is one X-only and one Y-only address, and in the")
	say("vanilla layout they are ADJACENT with X first. If nothing here qualifies, the offsets")
	say("are not in this neighbourhood and the vanilla+7 hunch was wrong -- say so, do not stretch.")
end

local function tick()
	frames = frames + 1
	if phase > 2 or frames % SAMPLE_EVERY ~= 0 then
		return
	end

	local changed = false
	for a = FIRST, LAST do
		local now = u8(a)
		if now ~= prev[a] then
			changes[phase][a] = changes[phase][a] + 1
			seen[phase][a][now] = true
			prev[a] = now
			changed = true
		end
	end

	if changed then
		local parts = {}
		for a = FIRST, LAST do
			parts[#parts + 1] = string.format("%4d", u8(a))
		end
		local extra = {}
		for _, a in ipairs(EXTRA) do
			extra[#extra + 1] = string.format("%04X=%d", a, u8(a))
		end
		log(string.format("%-6d %3d %3d | %s || %s", phase, u8(X), u8(Y),
			table.concat(parts, "  "), table.concat(extra, " ")))
	end

	if frames >= PHASE_FRAMES * phase then
		if phase == 1 then
			phase = 2
			say("PHASE 2 (20s): walk UP and DOWN.")
		else
			phase = 3
			report()
		end
	end
end

while true do
	tick()
	emu.frameadvance()
end
