-- MeshGhost — Crystal/Archipelago: confirm the player's coordinates BY REVERSAL, in one run
--
-- READ-ONLY. Writes nothing.
--
-- WHY THIS AND NOT ap_coord_probe.lua
-- The one-direction probe stopped at the FIRST address to reach its threshold, so every run
-- reported whichever byte happened to win that race — 0x0FC4, then 0x011E, then 0x016B, then
-- 0x14CD across four runs on 2026-08-18. Four runs, four different "candidates" is not a
-- measurement, and hard-excluding each winner in turn just hands the race to the next counter.
--
-- The discriminator is REVERSAL, and it needs no anchor and no published address:
--
--     a coordinate moves +1 walking one way and -1 walking back. A counter keeps counting.
--
-- So do both halves in ONE run, over ALL addresses at once, and report only the survivors of both.
-- Nothing is excluded up front — 0x0FC4 is scanned like everything else, and failing reversal is
-- then evidence rather than an assumption carried forward.
--
-- HOW TO RUN
--   1. Load the ARCHIPELAGO Crystal ROM. Stand in a corridor or on a route with 8+ clear tiles
--      in a straight line, room to walk back the same way.
--   2. Lua Console -> Script -> Open, pick this file.
--   3. PHASE A lasts 15 seconds: walk steadily ONE direction the whole time, 8+ tiles. Do not
--      turn, do not enter a door. The console counts down.
--   4. PHASE B lasts another 15 seconds: the script tells you to turn around; walk BACK the way
--      you came.
--   5. Read the report. Survivors are bytes that moved one way, then the other, consistently.
--      Log: ap_reverse_<timestamp>.log beside this script.
--
--   Then run it AGAIN on the other axis (if the first run was left/right, do up/down). The byte
--   that only moves on one axis is that axis's coordinate; a byte that moves on both is neither.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000
local SAMPLE_EVERY = 10 -- frames. A step takes ~16, so this cannot miss one, and scanning 32k
-- every other frame is more than BizHawk's Lua host will carry — the first version of the
-- one-direction probe never produced a log at all because of it (2026-08-18).

-- Each phase runs for a FIXED length rather than closing on the first address to reach a
-- threshold. That race is exactly what made the one-direction probe report a different byte every
-- run: a counter ticking on a frame timer reaches any hit count long before a walking player does,
-- so closing on it ends the phase while the real coordinate has moved once or twice.
local PHASE_FRAMES = 900 -- ~15 seconds at 60fps, comfortably 8+ tiles of walking
local KEEP_HITS = 3      -- an address needs at least this many in phase A to be carried forward
local PHASE_B_HITS = 3   -- consistent changes of the OPPOSITE sign to confirm

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		local d = info.source:sub(2):match("^(.*)[/\\]")
		if d and #d > 0 then
			return d
		end
	end
	local p = io.popen and io.popen("cd")
	if p then
		local out = p:read("*l")
		p:close()
		if out and #out > 0 then
			return out
		end
	end
	return "."
end

local logfile = io.open(string.format("%s/ap_reverse_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

log("=== MeshGhost Crystal/AP coordinate probe, BY REVERSAL (READ-ONLY) ===")
log("PHASE A: walk steadily ONE direction, 8+ tiles. No turning, no doors.")
log("Nothing is excluded up front. Failing reversal is the evidence.")

local prev, hits, dir = {}, {}, {}
for a = 0, WRAM_SIZE - 1 do
	prev[a] = u8(a)
	hits[a] = 0
end

local phase = "A"
local carried = {}       -- addr -> direction seen in phase A
local carriedList = {}
local frames = 0
local phaseAEnd = PHASE_FRAMES
local phaseBEnd = PHASE_FRAMES * 2
local finished = false

local function step(addr, now, was)
	local d = now - was
	if d == 1 or d == -1 then
		if hits[addr] == 0 or dir[addr] == d then
			dir[addr] = d
			hits[addr] = hits[addr] + 1
			return
		end
	end
	-- a jump, or a change of direction mid-phase: not what we are walking
	hits[addr] = 0
	dir[addr] = nil
end

local function closePhaseA()
	log(string.format("=== PHASE A closed (%d frames): everything with %d+ consistent ±1 changes ===",
		PHASE_FRAMES, KEEP_HITS))
	local shown = 0
	for a = 0, WRAM_SIZE - 1 do
		if hits[a] >= KEEP_HITS then
			carried[a] = dir[a]
			carriedList[#carriedList + 1] = a
			shown = shown + 1
			if shown <= 60 then
				log(string.format("  0x%04X (%5d)  moved %+d, %d time(s), now %s",
					a, a, dir[a], hits[a], tostring(u8(a))))
			end
		end
	end
	if shown > 60 then
		log(string.format("  ... and %d more (all still watched in phase B)", shown - 60))
	end
	log(string.format("%d address(es) carried into phase B.", #carriedList))
	log("")
	log(">>> NOW TURN AROUND AND WALK BACK THE SAME WAY, 8+ tiles. <<<")
	log("A coordinate now moves the OTHER way. A counter keeps going the same way and is dropped.")
	-- reset for phase B: only carried addresses are watched, and only the opposite sign counts
	for a = 0, WRAM_SIZE - 1 do
		hits[a] = 0
		prev[a] = u8(a)
	end
	phase = "B"
end

local function report()
	log("=== RESULT ===")
	local survivors = {}
	for _, a in ipairs(carriedList) do
		if hits[a] >= PHASE_B_HITS and dir[a] == -carried[a] then
			survivors[#survivors + 1] = a
		end
	end
	if #survivors == 0 then
		log("No address reversed. Either phase B was too short, or the walk was not the reverse")
		log("of phase A. Re-run; do not read anything into the phase A list on its own.")
	end
	for _, a in ipairs(survivors) do
		log(string.format("CONFIRMED BY REVERSAL: 0x%04X (%d)  %+d then %+d",
			a, a, carried[a], dir[a]))
		-- neighbours, because in vanilla the map group, map number and both coordinates sit
		-- together: a cluster around a survivor is a strong sign of the whole block.
		local ctx = {}
		for o = -4, 4 do
			local n = a + o
			if n >= 0 and n < WRAM_SIZE then
				ctx[#ctx + 1] = string.format("%s%02X", o == 0 and "[" or " ", u8(n) or 0)
					.. (o == 0 and "]" or "")
			end
		end
		log(string.format("    0x%04X-0x%04X: %s", a - 4, a + 4, table.concat(ctx, " ")))
	end
	log("--- dropped in phase B (kept counting the same way, so not a coordinate) ---")
	local dropped = 0
	for _, a in ipairs(carriedList) do
		if not (hits[a] >= PHASE_B_HITS and dir[a] == -carried[a]) then
			dropped = dropped + 1
			if dropped <= 40 then
				log(string.format("  0x%04X (%5d)  phase A %+d, phase B %s x%d",
					a, a, carried[a], dir[a] and string.format("%+d", dir[a]) or "none", hits[a]))
			end
		end
	end
	if dropped > 40 then
		log(string.format("  ... and %d more dropped", dropped - 40))
	end
	log("Run again on the OTHER axis to tell wXCoord from wYCoord.")
end

local function tick()
	frames = frames + 1
	if finished or frames % SAMPLE_EVERY ~= 0 then
		return
	end

	local best = 0
	if phase == "A" then
		for a = 0, WRAM_SIZE - 1 do
			local now, was = u8(a), prev[a]
			if now and was and now ~= was then
				step(a, now, was)
				prev[a] = now
			end
			if hits[a] > best then
				best = hits[a]
			end
		end
	else
		for _, a in ipairs(carriedList) do
			local now, was = u8(a), prev[a]
			if now and was and now ~= was then
				step(a, now, was)
				prev[a] = now
			end
			if hits[a] > best then
				best = hits[a]
			end
		end
	end

	if frames % 120 == 0 then
		local left = ((phase == "A") and phaseAEnd or phaseBEnd) - frames
		log(string.format("  [phase %s] best run so far: %d consistent steps, %d seconds left",
			phase, best, math.floor(left / 60)))
	end

	if phase == "A" and frames >= phaseAEnd then
		closePhaseA()
	elseif phase == "B" and frames >= phaseBEnd then
		report()
		finished = true
	end
end

while true do
	tick()
	emu.frameadvance()
end
