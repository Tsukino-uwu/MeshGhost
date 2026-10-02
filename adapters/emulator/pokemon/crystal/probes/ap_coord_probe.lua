-- Finds the player's coordinates on the Archipelago build with no anchor: walked one way, a coordinate keeps changing
-- by the same +1 or -1, and nothing else does for long. Read-only. Run on the AP ROM: walk 6+ tiles one way, no turns,
-- no doors; a second run on the other axis tells X from Y. Logs ap_coord_<timestamp>.log beside this script.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000
local NEEDED_HITS = 5 -- consistent ±1 changes before an address is reported

-- A counter, not a coordinate (it moved +1 walking right and walking left), which would win the race to NEEDED_HITS.
local EXCLUDE = { [0x0FC4] = true }
-- A step takes ~16 frames, so this cannot miss one; scanning 32 KB much more often stalls BizHawk's Lua host.
local SAMPLE_EVERY = 10

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
		-- Every 20 lines, never per line: bounded cost, and the log stays live through a run.
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

log("=== MeshGhost Crystal/AP coordinate probe (READ-ONLY) ===")
log("WALK STEADILY IN ONE DIRECTION, 6+ tiles, no turning, no doors.")
log("Looking for bytes that change by the same +1 or -1, repeatedly.")
log("NOTE: one direction only. A square resets the counter at every turn and finds nothing.")

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
				-- Walked one way, a coordinate always moves the same way; a counter or timer does not.
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
