-- MeshGhost — Crystal/Archipelago: which byte is wBattleMode
--
-- READ-ONLY. Writes nothing, spawns nothing.
--
-- WHY
-- Two state runs intersected to 64 candidates, and 10 of them read exactly 1 during BOTH battles.
-- That is consistent rather than conclusive: 1 is the commonest non-zero byte in memory, and a
-- snapshot only proves a value at one instant.
--
-- Two things separate the real one, and this probe collects both in a single session:
--
--   1. DURATION. wBattleMode is non-zero for the WHOLE battle and returns to 0 when it ends. A
--      byte that happened to be 1 at the sampled moment flickers instead.
--   2. WILD vs TRAINER. The vanilla semantics -- already relied on by the working adapter -- are
--      0 outside, 1 wild, 2 trainer. Both earlier battles were wild, so nothing yet has asked a
--      candidate to hold a DIFFERENT non-zero value. A trainer battle does.
--
-- 0x0FB1 rides along as context: it is the measured wMapStatus, 2 in the overworld and 0 in a
-- battle, so it marks where each battle starts and ends without assuming any of the candidates.
--
-- HOW TO RUN -- one session, 3 minutes, nothing to time
--   1. Load the ARCHIPELAGO Crystal ROM, stand in the overworld.
--   2. Lua Console -> Script -> Open, pick this file.
--   3. Get into a WILD battle and see it through to the end (run away is fine).
--   4. Then fight a TRAINER if one is reachable, and see that through too. If none is nearby,
--      the duration half still narrows it -- say so and the remaining candidates get a trainer
--      run later.
--      Log: ap_battle_<timestamp>.log beside this script. Console gets the battle boundaries.

local DOMAIN = "WRAM"
local RUN_FRAMES = 10800 -- 3 minutes
local SAMPLE_EVERY = 6

local W_MAPSTATUS = 0x0FB1 -- MEASURED: the single survivor of two state runs (verified.md)
local MAPSTATUS_HANDLE = 2

-- The 10 that read 1 in both earlier battles, in address order. No favourites.
local WATCH = { 0x015A, 0x01F6, 0x0210, 0x0228, 0x0279, 0x028C, 0x02BC, 0x1234, 0x143E, 0x14F8 }

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

local logfile = io.open(string.format("%s/ap_battle_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
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

say("=== MeshGhost Crystal/AP wBattleMode probe (READ-ONLY) ===")
say("Fight a WILD battle to the end, then a TRAINER if one is reachable. 3 minutes.")

local header = {}
for _, a in ipairs(WATCH) do
	header[#header + 1] = string.format("%04X", a)
end
log("")
log("event         status | " .. table.concat(header, "  "))

-- Per candidate, per battle: the values it held and for how many samples. A byte that is the real
-- flag holds ONE non-zero value for essentially the whole battle.
local held = {}
for _, a in ipairs(WATCH) do
	held[a] = {}
end

local frames, inBattle, battles, samples = 0, false, 0, 0
local prev = {}

local function rowText()
	local parts = {}
	for _, a in ipairs(WATCH) do
		parts[#parts + 1] = string.format("%4d", u8(a))
	end
	return table.concat(parts, "  ")
end

local function report()
	log("")
	say(string.format("=== RESULT after %d battle(s) ===", battles))
	if battles == 0 then
		say("No battle was seen (wMapStatus never left 2). Nothing can be concluded; re-run.")
		return
	end
	for _, a in ipairs(WATCH) do
		local parts, total, top, topv = {}, 0, 0, nil
		for v, n in pairs(held[a]) do
			parts[#parts + 1] = string.format("%d for %d%%", v, math.floor(n * 100 / samples))
			total = total + n
			if v ~= 0 and n > top then
				top, topv = n, v
			end
		end
		table.sort(parts)
		local verdict = "-- flickers, or is zero: not the flag"
		if topv and top >= samples * 0.9 then
			verdict = string.format("<-- held %d for %d%% of all battle time", topv,
				math.floor(top * 100 / samples))
		end
		say(string.format("  0x%04X: %s  %s", a, table.concat(parts, ", "), verdict))
	end
	say("The flag holds ONE non-zero value for nearly all battle time. If two survive that and you")
	say("fought both a wild and a trainer battle, the one that showed TWO different non-zero")
	say("values across the two battles is wBattleMode; vanilla semantics are 1 wild, 2 trainer.")
end

local function tick()
	frames = frames + 1
	if frames > RUN_FRAMES or frames % SAMPLE_EVERY ~= 0 then
		return
	end

	local status = u8(W_MAPSTATUS)
	local nowInBattle = status ~= MAPSTATUS_HANDLE

	if nowInBattle and not inBattle then
		battles = battles + 1
		say(string.format("battle %d started (wMapStatus %d -> %d)", battles, MAPSTATUS_HANDLE,
			status))
		log(string.format("%-13s %6d | %s", "battle start", status, rowText()))
	elseif inBattle and not nowInBattle then
		say(string.format("battle %d ended", battles))
		log(string.format("%-13s %6d | %s", "battle end", status, rowText()))
	end
	inBattle = nowInBattle

	if inBattle then
		samples = samples + 1
		for _, a in ipairs(WATCH) do
			local v = u8(a)
			held[a][v] = (held[a][v] or 0) + 1
		end
	end

	-- a compact trace, only when something actually moves
	local now = rowText()
	if now ~= prev.row then
		log(string.format("%-13s %6d | %s", inBattle and "in battle" or "overworld", status, now))
		prev.row = now
	end

	if frames == RUN_FRAMES then
		report()
	end
end

while true do
	tick()
	emu.frameadvance()
end
