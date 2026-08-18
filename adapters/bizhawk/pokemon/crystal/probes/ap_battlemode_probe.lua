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
-- HOW TO RUN -- no fixed length, and no waiting around
--   1. Load the ARCHIPELAGO Crystal ROM, stand in the overworld.
--   2. Lua Console -> Script -> Open, pick this file.
--   3. Get into a WILD battle and see it through to the end (running away is fine). The verdict
--      prints the moment that battle ends. One wild battle is a complete run: stop there.
--   4. It keeps watching, so any later battle re-reports with all of them compared. A TRAINER
--      battle is what finally separates a tie, whenever one happens to be reachable.
--      Log: ap_battle_<timestamp>.log beside this script. Console gets the battle boundaries.

local DOMAIN = "WRAM"
local SAMPLE_EVERY = 6

local W_MAPSTATUS = 0x0FB1 -- MEASURED: the single survivor of two state runs (verified.md)
local MAPSTATUS_HANDLE = 2

-- A battle is wMapStatus == 0, NOT "anything other than 2". Found the hard way on the first run
-- (2026-08-18): between two wild battles the byte reads 1, never 2 -- the map is re-entering after
-- the first battle when the second encounter starts. Treating 1 as "still in battle" merged both
-- battles AND the walk between them into one window, so every candidate that correctly dropped to
-- 0 in the gap was scored as "flickers". Nine real candidates were thrown away by that.
--
-- The three values behave exactly like wMapStatus's own: 0 no map, 1 map entering, 2 map handled.
-- Worth noting the adapter's gate already wants == 2 specifically, which excludes the entering
-- state too -- a ghost has no business existing while the map is still being set up.
local MAPSTATUS_NO_MAP = 0

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
say("Fight a wild battle to the end. It reports the moment each battle ends -- no fixed length.")
say("A second battle of any kind reports again, comparing them.")

local header = {}
for _, a in ipairs(WATCH) do
	header[#header + 1] = string.format("%04X", a)
end
log("")
log("event         status | " .. table.concat(header, "  "))

-- Per candidate, per battle: the values it held and for how many samples. A byte that is the real
-- flag holds ONE non-zero value for essentially the whole battle. Kept per battle rather than
-- pooled, so a wild and a trainer battle can be compared against each other later.
local held, samples = {}, {}

local frames, inBattle, battles = 0, false, 0
local prev = {}

local function rowText()
	local parts = {}
	for _, a in ipairs(WATCH) do
		parts[#parts + 1] = string.format("%4d", u8(a))
	end
	return table.concat(parts, "  ")
end

-- The value a candidate held for at least 90% of one battle, or nil if it flickered instead.
local function steadyValue(a, b)
	local top, topv = 0, nil
	for v, n in pairs(held[b][a] or {}) do
		if v ~= 0 and n > top then
			top, topv = n, v
		end
	end
	if topv and top >= samples[b] * 0.9 then
		return topv, math.floor(top * 100 / samples[b])
	end
end

local function report()
	log("")
	say(string.format("=== RESULT after battle %d ===", battles))
	local survivors = {}
	for _, a in ipairs(WATCH) do
		local parts, steady = {}, true
		for b = 1, battles do
			local v, pct = steadyValue(a, b)
			if v then
				parts[#parts + 1] = string.format("battle %d: %d (%d%%)", b, v, pct)
			else
				parts[#parts + 1] = string.format("battle %d: flickers", b)
				steady = false
			end
		end
		if steady then
			survivors[#survivors + 1] = a
		end
		say(string.format("  0x%04X: %s%s", a, table.concat(parts, ", "),
			steady and "   <-- steady" or ""))
	end

	say(string.format("%d candidate(s) held one value for a whole battle.", #survivors))
	if battles < 2 then
		say("That is a complete run. A later battle -- a TRAINER one especially -- reports again")
		say("and separates any tie: the real flag then shows a DIFFERENT non-zero value (vanilla")
		say("semantics are 1 wild, 2 trainer) where a coincidence repeats itself.")
		return
	end

	local split = {}
	for _, a in ipairs(survivors) do
		local first = steadyValue(a, 1)
		for b = 2, battles do
			if steadyValue(a, b) ~= first then
				split[#split + 1] = a
				break
			end
		end
	end
	if #split == 0 then
		say("None showed two different values. Expected if the battles were the same KIND --")
		say("one wild and one trainer are what separate them.")
	end
	for _, a in ipairs(split) do
		say(string.format("0x%04X held DIFFERENT values across battles — this is wBattleMode.", a))
	end
end

local function tick()
	frames = frames + 1
	if frames % SAMPLE_EVERY ~= 0 then
		return
	end

	local status = u8(W_MAPSTATUS)
	local nowInBattle = status == MAPSTATUS_NO_MAP

	if nowInBattle and not inBattle then
		battles = battles + 1
		held[battles], samples[battles] = {}, 0
		for _, a in ipairs(WATCH) do
			held[battles][a] = {}
		end
		say(string.format("battle %d started (wMapStatus -> %d)", battles, status))
		log(string.format("%-13s %6d | %s", "battle start", status, rowText()))
	elseif inBattle and not nowInBattle then
		say(string.format("battle %d ended", battles))
		log(string.format("%-13s %6d | %s", "battle end", status, rowText()))
		-- Report the moment it ends rather than at some fixed finish time. The answer is ready
		-- now, and waiting out a timer spends the user's session for nothing (probes.md).
		report()
	end
	inBattle = nowInBattle

	if inBattle then
		samples[battles] = samples[battles] + 1
		for _, a in ipairs(WATCH) do
			local v = u8(a)
			held[battles][a][v] = (held[battles][a][v] or 0) + 1
		end
	end

	-- a compact trace, only when something actually moves
	local now = rowText()
	if now ~= prev.row then
		log(string.format("%-13s %6d | %s", inBattle and "in battle" or "overworld", status, now))
		prev.row = now
	end

end

while true do
	tick()
	emu.frameadvance()
end
