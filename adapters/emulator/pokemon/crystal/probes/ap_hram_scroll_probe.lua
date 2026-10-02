-- Crystal/Archipelago: finds hSCX/hSCY (the camera) by sweeping all of HRAM for its signature. Read-only, no input.
-- A camera byte is constant while standing, changes several times within a step, moves on one axis only, and walks a
-- run of evenly spaced values. Stand still 5s, walk left and right 15s, then up and down 15s, as prompted; on
-- vanilla it must find $FFCF/$FFD0 and nothing else. A bump costs coverage, never a false hit: the camera stays put.

-- System Bus, not WRAM: HRAM is not in the WRAM domain.
local DOMAIN = "System Bus"
local LO, HI = 0xFF80, 0xFFFE

local SAMPLE_EVERY = 2 -- frames: a camera changes several times inside one step

local STILL_FRAMES = 300
local AXIS_FRAMES = 900

-- Vanilla's pair, reported by name so a run says whether it holds on this build.
local ASSUMED_X, ASSUMED_Y = 0xFFCF, 0xFFD0

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

local logfile = io.open(string.format("%s/ap_hram_scroll_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local flushEvery = 0
local function log(msg)
	if logfile then
		logfile:write(msg, "\n")
		-- Flushed every 20 lines: bounded cost, and a live log (an unflushed one reads as nothing happened).
		flushEvery = flushEvery + 1
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
	return nil -- a failed read must not look like a byte holding zero
end

say("=== MeshGhost Crystal/AP HRAM camera probe (READ-ONLY) ===")
say(string.format("sweeping $%04X-$%04X on the %s domain -- every byte, nothing filtered",
	LO, HI, DOMAIN))
say("PHASE 1 (5s): STAND COMPLETELY STILL. Do not touch the d-pad.")

local prev, movedStill, movedX, movedY, values, unreadable = {}, {}, {}, {}, {}, {}
for a = LO, HI do
	prev[a] = u8(a)
	if prev[a] == nil then
		unreadable[a] = true
	end
	movedStill[a], movedX[a], movedY[a] = 0, 0, 0
	values[a] = { n = 0 }
end

local phase, frames = 1, 0

local function scan(counter)
	for a = LO, HI do
		local now = u8(a)
		if now ~= nil and prev[a] ~= nil and now ~= prev[a] then
			counter[a] = counter[a] + 1
			local v = values[a]
			-- Capped: 40 is more distinct values than a camera shows in a phase, and fewer than a counter does.
			if not v[now] and v.n < 40 then
				v[now] = true
				v.n = v.n + 1
			end
		end
		if now ~= nil then
			prev[a] = now
		end
	end
end

local function valuesAt(a)
	local vs = {}
	for v in pairs(values[a]) do
		if type(v) == "number" then
			vs[#vs + 1] = v
		end
	end
	table.sort(vs)
	return vs
end

-- A camera steps by a constant stride, so its values are evenly spaced: reported as the commonest gap and its share.
local function runShape(a)
	local vs = valuesAt(a)
	if #vs < 3 then
		return "only " .. #vs .. " distinct value(s) -- not a run"
	end
	local gaps, best, bestN = {}, nil, 0
	for i = 2, #vs do
		local g = vs[i] - vs[i - 1]
		gaps[g] = (gaps[g] or 0) + 1
		if gaps[g] > bestN then
			best, bestN = g, gaps[g]
		end
	end
	return string.format("%d distinct, commonest gap %d on %d of %d steps",
		#vs, best or -1, bestN, #vs - 1)
end

local function describe(a, label)
	local vs = valuesAt(a)
	local shown = {}
	for i = 1, math.min(#vs, 24) do
		shown[#shown + 1] = tostring(vs[i])
	end
	say(string.format("  $%04X %-14s still:%d  x:%d  y:%d   %s", a, label,
		movedStill[a], movedX[a], movedY[a], runShape(a)))
	say(string.format("           values: %s%s", table.concat(shown, " "),
		#vs > 24 and " ..." or ""))
end

local function report()
	say("=== RESULT ===")

	local nUnreadable = 0
	for _ in pairs(unreadable) do
		nUnreadable = nUnreadable + 1
	end
	-- An instrument reports its own coverage, not only its findings.
	say(string.format("coverage: %d bytes swept, %d never readable",
		HI - LO + 1, nUnreadable))

	local hitsX, hitsY = {}, {}
	for a = LO, HI do
		if movedStill[a] == 0 then
			if movedX[a] >= 8 and movedY[a] == 0 then
				hitsX[#hitsX + 1] = a
			elseif movedY[a] >= 8 and movedX[a] == 0 then
				hitsY[#hitsY + 1] = a
			end
		end
	end

	say(string.format("X CANDIDATES (%d): still while standing, moved on left/right ONLY", #hitsX))
	for _, a in ipairs(hitsX) do
		describe(a, "")
	end
	say(string.format("Y CANDIDATES (%d): still while standing, moved on up/down ONLY", #hitsY))
	for _, a in ipairs(hitsY) do
		describe(a, "")
	end

	-- Everything that moved, unfiltered: the strict test above drops a byte that twitched once on the other axis.
	say("--- EVERY address that moved at all, strongest first, NO filtering ---")
	local movers = {}
	for a = LO, HI do
		local total = movedStill[a] + movedX[a] + movedY[a]
		if total > 0 then
			movers[#movers + 1] = { a = a, total = total }
		end
	end
	table.sort(movers, function(p, q) return p.total > q.total end)
	for _, m in ipairs(movers) do
		describe(m.a, "")
	end
	say(string.format("(%d of %d bytes moved at all)", #movers, HI - LO + 1))

	say("--- the pair this adapter is USING right now, whatever the sweep says ---")
	describe(ASSUMED_X, "(assumed X)")
	describe(ASSUMED_Y, "(assumed Y)")
	local xOk = movedStill[ASSUMED_X] == 0 and movedX[ASSUMED_X] >= 8 and movedY[ASSUMED_X] == 0
	local yOk = movedStill[ASSUMED_Y] == 0 and movedY[ASSUMED_Y] >= 8 and movedX[ASSUMED_Y] == 0
	if xOk and yOk then
		say("VERDICT: both behave like the camera on this build -- the assumption HOLDS, and the")
		say("gliding ghost has a different cause. Do not change the addresses on this evidence.")
	else
		say(string.format("VERDICT: the assumption does NOT hold here (X %s, Y %s). The camera on",
			xOk and "ok" or "FAILS", yOk and "ok" or "FAILS"))
		say("this build is one of the candidates above, if any -- confirm the run shape before")
		say("adopting one, and measure again on a second map before writing it into ADDRESSES.")
	end
	say("A camera walks a RUN of evenly spaced values. Two or three values is a flag that happened")
	say("to flip while you walked, and a gap that is never constant is a timer.")
	if logfile then
		pcall(function() logfile:flush() end)
	end
end

local function tick()
	frames = frames + 1
	if phase > 3 or frames % SAMPLE_EVERY ~= 0 then
		return
	end

	if phase == 1 then
		scan(movedStill)
		if frames >= STILL_FRAMES then
			phase, frames = 2, 0
			say("PHASE 2 (15s): walk LEFT and RIGHT, back and forth. Keep moving.")
		end
	elseif phase == 2 then
		scan(movedX)
		if frames >= AXIS_FRAMES then
			phase, frames = 3, 0
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

-- Under the dev loader the adapter stays attached and keeps the ghost on screen while this measures.
if MESHGHOST_DEV_LOADER then
	MESHGHOST_DEV_TICK = tick
else
	while true do
		tick()
		emu.frameadvance()
	end
end
