-- Read-only, on an Archipelago ROM: prints the scroll-offset neighbourhood (flat 0x114C-0x1159) as you walk, so the
-- pair that behaves like a scroll offset (one axis each, cycling through a run of values within a step) shows
-- itself; vanilla+7 is a hypothesis from a delta, so it is watched rather than believed. Walk left and right for
-- 20 seconds, then up and down for 20.

local DOMAIN = "WRAM"
local SAMPLE_EVERY = 2 -- a scroll offset changes within a step; 14 bytes a sample costs nothing

local FIRST = 0x114C
local LAST = 0x1159

local X, Y = 0x1CBF, 0x1CBE -- the player's coordinates, measured on this build

-- Context: which of these two wMapStatus candidates holds 2 through normal play.
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
		-- Flush every 20 lines: a bounded cost, and a log that is never empty for a whole run.
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
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

-- Per address and phase, distinct values and changes: a scroll offset takes many values on its own axis, a flag two.
-- Scored by the phase walked, not the axis that stepped, so a sideways drift flips the verdict: re-score by x/y.
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
