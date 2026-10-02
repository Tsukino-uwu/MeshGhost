-- Finds wMapGroup, wMapNumber, wMapStatus and wBattleMode on the Archipelago build by reversal applied to state: keeps
-- the bytes that follow vanilla's meaning across the overworld, another map, a battle and back. Read-only. Run on the
-- AP ROM and follow the console's four countdown phases (the battle need not be timed). Logs ap_state_<timestamp>.log.

local DOMAIN = "WRAM"
local WRAM_SIZE = 0x8000

local MAPSTATUS_HANDLE = 2 -- vanilla semantics, from the working adapter -- not an address

-- The two bytes before wYCoord, constant on one map in the coordinate run: flagged in the report, never favoured.
local SUSPECTED = { [0x1CBC] = "suspected wMapGroup", [0x1CBD] = "suspected wMapNumber" }

local PHASES = {
	{ name = "1: OVERWORLD", frames = 900, hint = "Stand still in the overworld." },
	{ name = "2: ANOTHER MAP", frames = 1800, hint = "Go to a DIFFERENT map, then stand still." },
	{ name = "3: IN A BATTLE", frames = 3600, hint = "Get into a battle and stay in it." },
	{ name = "4: BACK OUT", frames = 1800, hint = "End the battle, stand still in the overworld." },
}

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

local logfile = io.open(string.format("%s/ap_state_%s.log", scriptDir(),
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

local function snapshot()
	local t = {}
	for a = 0, WRAM_SIZE - 1 do
		local ok, v = pcall(memory.read_u8, a, DOMAIN)
		t[a] = (ok and type(v) == "number") and v or 0
	end
	return t
end

local function differs(a, b)
	local n = 0
	for i = 0, WRAM_SIZE - 1 do
		if a[i] ~= b[i] then
			n = n + 1
		end
	end
	return n
end

say("=== MeshGhost Crystal/AP map + state probe (READ-ONLY) ===")
say("Four phases on a countdown. Detail goes to the log file; console gets the summary.")
say(PHASES[1].name .. " -- " .. PHASES[1].hint)

local snaps = {}
local phase, frames, elapsed = 1, 0, 0
local best, bestDiff = nil, -1 -- phase 3 only: the moment least like the overworld

local function report()
	local s1, s2, s3, s4 = snaps[1], snaps[2], snaps[3], snaps[4]

	local map, battle, status = {}, {}, {}
	for a = 0, WRAM_SIZE - 1 do
		if s1[a] ~= s2[a] and s3[a] == s2[a] and s4[a] == s2[a] then
			map[#map + 1] = a
		end
		if s1[a] == 0 and s2[a] == 0 and s3[a] ~= 0 and s4[a] == 0 then
			battle[#battle + 1] = a
		end
		if s1[a] == MAPSTATUS_HANDLE and s2[a] == MAPSTATUS_HANDLE and s3[a] ~= MAPSTATUS_HANDLE
			and s4[a] == MAPSTATUS_HANDLE then
			status[#status + 1] = a
		end
	end

	local function dump(title, list, note)
		say(string.format("%s: %d candidate(s)", title, #list))
		log("  " .. note)
		for _, a in ipairs(list) do
			local mark = SUSPECTED[a] and ("   <-- " .. SUSPECTED[a]) or ""
			local line = string.format("  0x%04X (%5d)  overworld=%d map2=%d battle=%d after=%d%s",
				a, a, s1[a], s2[a], s3[a], s4[a], mark)
			log(line)
			if #list <= 12 or SUSPECTED[a] then
				console.log(line)
			end
		end
		if #list > 12 then
			say(string.format("  (%d listed in the log; console shows only flagged ones)", #list))
		end
	end

	say("=== RESULT ===")
	dump("wMapGroup / wMapNumber", map,
		"Expect a PAIR of adjacent addresses, values small (map groups are single digits to ~26).")
	dump("wBattleMode", battle, "Expect very few. It is 0 outside a battle and non-zero inside.")
	dump("wMapStatus", status, "Expect very few. 2 = MAPSTATUS_HANDLE, the value the gate wants.")
	say("Nothing here is filled into the adapter until a second run agrees -- a single run cannot")
	say("tell a state flag from a byte that happened to move the same way once.")
end

local function tick()
	frames = frames + 1
	if phase > #PHASES then
		return
	end
	elapsed = elapsed + 1

	-- Phase 3 keeps the moment most unlike the overworld. Every 2 seconds: a snapshot is 32k reads across the host
	-- boundary, and 120 of them in one phase silently stalls the host.
	if phase == 3 and elapsed % 120 == 0 then
		local now = snapshot()
		local d = differs(now, snaps[2])
		if d > bestDiff then
			bestDiff, best = d, now
		end
	end

	if elapsed % 120 == 0 then
		say(string.format("  [%s] %d seconds left", PHASES[phase].name,
			math.floor((PHASES[phase].frames - elapsed) / 60)))
	end

	if elapsed >= PHASES[phase].frames then
		if phase == 3 then
			snaps[3] = best or snapshot()
			say(string.format("  captured the battle moment: %d bytes unlike the overworld",
				bestDiff))
		else
			snaps[phase] = snapshot()
		end
		phase, elapsed = phase + 1, 0
		if phase > #PHASES then
			report()
		else
			say(PHASES[phase].name .. " -- " .. PHASES[phase].hint)
		end
	end
end

while true do
	tick()
	emu.frameadvance()
end
