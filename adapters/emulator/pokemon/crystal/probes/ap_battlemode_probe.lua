-- Crystal/Archipelago: which of ten candidate bytes is wBattleMode. Read-only; reports as each battle ends.
-- The real one holds one non-zero value for a whole battle and is 0 after. Vanilla's reads 1 in a wild battle and 2
-- in a trainer one, so a battle of each kind separates candidates that tie.

local DOMAIN = "WRAM"
local SAMPLE_EVERY = 6

local W_MAPSTATUS = 0x0FB1 -- the wMapStatus candidate two state runs left; the adapter reads 0x1439
local MAPSTATUS_HANDLE = 2

-- A battle is wMapStatus 0, not anything but 2: between two wild battles it reads 1 while the map re-enters.
local MAPSTATUS_NO_MAP = 0

-- The ten bytes that read 1 in both of two earlier wild battles.
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
		-- Flushed every 20 lines: bounded cost, and a live log (an unflushed one reads as nothing happened).
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

say("=== MeshGhost Crystal/AP wBattleMode probe (READ-ONLY) ===")
say("Fight a wild battle to the end. It reports the moment each battle ends -- no fixed length.")
say("A second battle of any kind reports again, comparing them.")

local header = {}
for _, a in ipairs(WATCH) do
	header[#header + 1] = string.format("%04X", a)
end
log("")
log("event         status | " .. table.concat(header, "  "))

-- Per battle, per candidate, the samples each value was seen for: kept per battle so two kinds can be compared.
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
