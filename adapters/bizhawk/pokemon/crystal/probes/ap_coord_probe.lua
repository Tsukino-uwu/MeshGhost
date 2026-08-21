-- MeshGhost — Crystal/Archipelago: find the player's coordinates by walking in one direction
--
-- READ-ONLY. Writes nothing.
--
-- WHY
-- The previous attempt DERIVED the coordinates: Archipelago publishes wMapGroup = 7359, and in the
-- vanilla decomp wMapGroup/wMapNumber/wYCoord/wXCoord are four consecutive bytes, so 7361/7362
-- should have been wYCoord/wXCoord. Walking a square refuted it — those addresses produced a
-- repeating cycle of deltas, which is a counter, not a player (verified.md, 2026-08-18).
--
-- A structural fact from the vanilla decomp is a fact about VANILLA, and rearranging structure is
-- the whole reason Archipelago is hard. So: measure, do not derive.
--
-- THE CIRCULARITY, AND THE WAY OUT
-- A differential scan needs to know WHEN a step happened, which normally means already knowing a
-- coordinate — the thing being searched for. The way out is to remove the need for a reference:
--
--     WALK IN ONE DIRECTION ONLY.
--
-- Then a coordinate is simply a byte that changes by the SAME ±1 several times over, and nothing
-- else in RAM does that for long. No anchor, no assumption, no published value trusted.
--
-- HOW TO RUN
--   1. Load the ARCHIPELAGO Crystal ROM. Stand somewhere with a long clear run — a route, or a
--      corridor. Indoors is fine if you have 5+ tiles in a line.
--   2. Lua Console -> Script -> Open, pick this file.
--   3. Walk STEADILY IN ONE DIRECTION, at least 6 tiles. Do not turn. Do not enter a door.
--   4. Read the report. Then, if you like, run it again walking a different direction: the axis
--      that changes tells you which coordinate is which.
--      Log: ap_coord_<timestamp>.log beside this script.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000
local NEEDED_HITS = 5 -- consistent ±1 changes before an address is reported

-- Addresses PROVEN to be counters rather than coordinates: they moved +1 while walking right AND
-- +1 while walking left (2026-08-18). A coordinate reverses with direction; a counter does not.
-- Excluded because the probe used to stop at the first address to reach the threshold, and the
-- counter won that race every run — hiding the real candidate behind it.
local EXCLUDE = { [0x0FC4] = true }
local SAMPLE_EVERY = 10 -- frames. A step takes ~16, so this still cannot miss one, and 32k reads
-- every other frame is far more than BizHawk's Lua host will carry — the first version of this
-- probe never produced a log at all because of it (2026-08-18).

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

local logfile = io.open(string.format("%s/ap_coord_%s.log", scriptDir(),
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

log("=== MeshGhost Crystal/AP coordinate probe (READ-ONLY) ===")
log("WALK STEADILY IN ONE DIRECTION, 6+ tiles, no turning, no doors.")
log("Looking for bytes that change by the same +1 or -1, repeatedly.")
log("NOTE: one direction only. A square resets the counter at every turn and finds nothing.")

-- state per address: last value, how many consistent ±1 steps seen, and which direction.
local prev, hits, dir = {}, {}, {}
for a = 0, WRAM_SIZE - 1 do
	prev[a] = u8(a)
	hits[a] = 0
end

local frames, reported = 0, false

local function tick()
	frames = frames + 1
	if reported or frames % SAMPLE_EVERY ~= 0 then
		return
	end

	local best = 0
	for a = 0, WRAM_SIZE - 1 do
		local now = u8(a)
		local was = prev[a]
		if now and was and now ~= was then
			local d = now - was
			if d == 1 or d == -1 then
				-- Consistent with what this address has done before? A coordinate walked in one
				-- direction always moves the same way; a counter or timer does not.
				if hits[a] == 0 or dir[a] == d then
					dir[a] = d
					hits[a] = hits[a] + 1
				else
					hits[a] = 0 -- changed direction: not what we are walking
				end
			else
				hits[a] = 0 -- jumped: a load, a counter wrapping, unrelated data
			end
			prev[a] = now
		end
		if EXCLUDE[a] then
			hits[a] = 0
		end
		if hits[a] > best then
			best = hits[a]
		end
	end

	if frames % 120 == 0 then
		log(string.format("  ... best run so far: %d consistent steps", best))
	end

	if best >= NEEDED_HITS then
		log(string.format("=== CANDIDATES after %d consistent ±1 changes ===", NEEDED_HITS))
		local n = 0
		for a = 0, WRAM_SIZE - 1 do
			if hits[a] >= NEEDED_HITS then
				n = n + 1
				log(string.format("  0x%04X (%d)  moved %+d each time, now %s",
					a, a, dir[a], tostring(u8(a))))
			end
		end
		log(string.format("%d candidate(s). The player's coordinate is among them.", n))
		log("Run again walking the OTHER axis to tell wXCoord from wYCoord: the one that moves")
		log("is the one for that axis. Neighbours matter too — in vanilla the map group, map")
		log("number and both coordinates sit together, so a cluster is a good sign.")
		reported = true
	end
end

while true do
	tick()
	emu.frameadvance()
end
