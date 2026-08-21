-- MeshGhost — Crystal/Archipelago: find wBGMapOffsetX / wBGMapOffsetY
--
-- READ-ONLY. Writes nothing, spawns nothing.
--
-- WHY
-- These two are the last addresses the Archipelago table is missing, and they are not a gate or an
-- identity — they are pixel scroll offsets, used to turn a map coordinate into a screen position
-- (screenCoords() in the adapter). Wrong ones do not refuse to work; they put a ghost a few pixels
-- off, every frame, which is the kind of wrong that gets blamed on interpolation for hours.
--
-- HOW — a shape no other address in this build has
-- Neither reversal nor state snapshots find these, because they are not ±1 per step and they do not
-- differ between two standing-still moments. Their signature is different, and it is very specific:
--
--   * CONSTANT while the player stands still, at any position.
--   * CHANGING while the player walks, several times within a single step, since a tile takes
--     several frames to slide past.
--   * AXIS-SPECIFIC: the X offset moves for left/right and not for up/down, and vice versa.
--
-- That third property is what makes this cheap and certain — the same disjointness that identified
-- the coordinates. Anything moving on both axes is a frame counter, an animation timer, or noise.
--
-- HOW TO RUN — about 35 seconds, nothing to time
--   1. Load the ARCHIPELAGO Crystal ROM, stand in the overworld with room to walk both ways.
--   2. Lua Console -> Script -> Open, pick this file.
--   3. PHASE 1 (5s)  STAND COMPLETELY STILL. Do not touch the d-pad.
--   4. PHASE 2 (15s) Walk LEFT and RIGHT, back and forth. Keep moving.
--   5. PHASE 3 (15s) Walk UP and DOWN, back and forth. Keep moving.
--      Log: ap_scroll_<timestamp>.log beside this script. Console gets the summary.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000
local SAMPLE_EVERY = 4 -- frames. Finer than the other probes on purpose: a scroll offset changes
-- several times inside one step, and sampling per step would see only its endpoints.

local STILL_FRAMES = 300
local AXIS_FRAMES = 900

local X, Y = 0x1CBF, 0x1CBE -- MEASURED (verified.md, 2026-08-18)

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

-- Per address: did it move while standing, while walking the X axis, while walking the Y axis.
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
		-- The whole test in one line: still while standing, moving on exactly one axis.
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
