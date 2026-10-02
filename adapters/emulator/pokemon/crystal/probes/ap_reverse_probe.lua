-- Crystal/Archipelago: finds the player's coordinates by reversal, in one run. Read-only; runs its own frame loop.
-- A coordinate moves +1 walking one way and -1 walking back, where a counter keeps counting. Walk one way 8+ tiles for
-- 15s, then back for 15s, as prompted; run it again on the other axis to tell wXCoord from wYCoord.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000
local SAMPLE_EVERY = 10 -- frames: a step takes ~16, and a 32K scan every other frame is more than the Lua host carries

-- Fixed-length phases: closing on the first address to reach a threshold lets a frame-timer counter win that race.
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
		-- Flushed every 20 lines: bounded cost, and a live log (an unflushed one reads as nothing happened).
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
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
		-- Its neighbours: in vanilla the map group, map number and both coordinates sit together.
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
