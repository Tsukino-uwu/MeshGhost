-- Finds wBGMapOffsetX/Y on the Archipelago build: a scroll offset is constant while standing, changes several times in
-- a step, and moves on one axis only. Read-only. Run on the AP ROM with room to walk: stand still, then walk
-- left/right, then up/down, as the console prompts. Logs ap_scroll_<timestamp>.log beside this script.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000
-- Finer than the other probes: an offset changes several times inside a step, and per-step samples see only the ends.
local SAMPLE_EVERY = 4

local STILL_FRAMES = 300
local AXIS_FRAMES = 900

local X, Y = 0x1CBF, 0x1CBE -- wXCoord, wYCoord on this build, measured by reversal

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

local logfile = io.open(string.format("%s/ap_scroll_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function log(msg)
	if logfile then
		logfile:write(msg, "\n")
		-- Every 20 lines, never per line: bounded cost, and the log stays live through a run.
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

say("=== MeshGhost Crystal/AP scroll-offset probe (READ-ONLY) ===")
say("PHASE 1 (5s): STAND COMPLETELY STILL.")

local prev, movedStill, movedX, movedY = {}, {}, {}, {}
local values = {} -- distinct values seen while walking, capped so one noisy byte cannot eat memory
for a = 0, WRAM_SIZE - 1 do
	prev[a] = u8(a)
	movedStill[a], movedX[a], movedY[a] = 0, 0, 0
	values[a] = {}
end

local phase, frames = 1, 0

local function scan(counter)
	for a = 0, WRAM_SIZE - 1 do
		local now = u8(a)
		if now ~= prev[a] then
			counter[a] = counter[a] + 1
			local v = values[a]
			if not v[now] and v.n ~= nil and v.n < 40 then
				v[now] = true
				v.n = v.n + 1
			elseif v.n == nil then
				v[now], v.n = true, 1
			end
			prev[a] = now
		end
	end
end

local function report()
	say("=== RESULT ===")
	local hits = { x = {}, y = {} }
	for a = 0, WRAM_SIZE - 1 do
		-- Still while standing, moving on exactly one axis.
		if movedStill[a] == 0 then
			if movedX[a] >= 8 and movedY[a] == 0 then
				hits.x[#hits.x + 1] = a
			elseif movedY[a] >= 8 and movedX[a] == 0 then
				hits.y[#hits.y + 1] = a
			end
		end
	end

	local function dump(axis, list, other)
		say(string.format("%s offset: %d candidate(s) — still while standing, moved only on %s",
			axis, #list, other))
		for _, a in ipairs(list) do
			local vs = {}
			for v in pairs(values[a]) do
				if type(v) == "number" then
					vs[#vs + 1] = v
				end
			end
			table.sort(vs)
			local shown = {}
			for i = 1, math.min(#vs, 20) do
				shown[#shown + 1] = tostring(vs[i])
			end
			local line = string.format("  0x%04X (%5d)  %d change(s), values seen: %s%s",
				a, a, axis == "X" and movedX[a] or movedY[a], table.concat(shown, " "),
				#vs > 20 and " ..." or "")
			say(line)
		end
	end

	dump("X", hits.x, "left/right")
	dump("Y", hits.y, "up/down")
	say("A scroll offset walks through a RUN of values (0 2 4 6 ... or 15 14 13 ...), not two or")
	say("three of them — that is what tells it from a flag that flips while you happen to walk.")
end

local function tick()
	frames = frames + 1
	if phase > 3 or frames % SAMPLE_EVERY ~= 0 then
		return
	end

	if phase == 1 then
		scan(movedStill)
		if frames >= STILL_FRAMES then
			phase = 2
			frames = 0
			say("PHASE 2 (15s): walk LEFT and RIGHT, back and forth. Keep moving.")
		end
	elseif phase == 2 then
		scan(movedX)
		if frames >= AXIS_FRAMES then
			phase = 3
			frames = 0
			say("PHASE 3 (15s): walk UP and DOWN, back and forth. Keep moving.")
		end
	else
		scan(movedY)
		if frames >= AXIS_FRAMES then
			phase = 4
			report()
		end
	end
end

while true do
	tick()
	emu.frameadvance()
end
