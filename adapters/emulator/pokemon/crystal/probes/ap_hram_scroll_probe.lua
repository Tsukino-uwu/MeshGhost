-- MeshGhost — Crystal/Archipelago: find hSCX / hSCY (the CAMERA) in HRAM
--
-- READ-ONLY. Writes nothing, spawns nothing, and takes no input.
--
-- WHY THIS EXISTS, and it was predicted before it was needed
-- `UNVERIFIED.md`, 2026-08-23, "the camera addresses bypass the adapter's own per-build table":
-- `hSCX`/`hSCY` are read as inline literals (`0xFFCF`/`0xFFD0`, System Bus) where every other
-- address in this adapter comes from the per-ROM-build table. Vanilla V1.0's pair comes from a
-- hash-verified local `pokecrystal` build. **The Archipelago build's are ASSUMED** — the argument
-- being that the patch moves WRAM (its `wPlayerBGMapOffset` is vanilla+7) while HRAM is small and
-- hardware-adjacent. That is a plausible argument, not a measurement, and that entry says exactly
-- what a wrong pair would look like: HRAM always reads, so it returns a believable scroll value
-- and the graceful fallback never fires.
--
-- Which is what a live mixed-room run then produced, 2026-08-26: on the ARCHIPELAGO instance a
-- peer standing perfectly still was drawn GLIDING as the local player walked, and stuck at the
-- edge of the screen once the player moved far enough away. Both are what a drawn ghost does when
-- the camera clock it is anchored to is not the camera. The vanilla instance, same build of this
-- adapter, same peer, was correct throughout.
--
-- HOW — the same correlation that found `W_BGMAPOFFSETX/Y` on this build, pointed at HRAM
-- A camera register's signature is very specific and nothing else in this range has it:
--
--   * CONSTANT while the player stands still, at any position on any map.
--   * CHANGING several times WITHIN one step, since a tile takes several frames to slide past.
--   * AXIS-SPECIFIC: the X register moves for left/right and not for up/down, and the reverse.
--   * It walks a RUN of values (0 2 4 6 ... or 254 252 250 ...), not two or three of them —
--     which is what tells a camera from a flag that happens to flip while you walk.
--
-- HRAM IS 127 BYTES, so this is a complete sweep rather than a search: $FF80-$FFFE, every one,
-- with nothing filtered before you look. (`probes.md`: a filter applied before you look is a guess
-- about the answer.) The whole scan is 127 reads every other frame and cannot cost a frame.
--
-- IT CHECKS ITS OWN ASSUMPTION BY NAME. Whatever the sweep finds, the report also states outright
-- what $FFCF and $FFD0 — the two the adapter is using right now — actually did, so the run either
-- confirms the assumption or names the pair that replaces it. A probe that returns only a search
-- result cannot tell you that the thing you already believed was right.
--
-- HOW TO RUN — about 40 seconds, and NOTHING TO TIME
-- Fixed phases with a countdown; you are asked for endurance, not for hitting a window.
--   1. On the ARCHIPELAGO ROM, stand in the overworld with room to walk both ways. (Run it on
--      VANILLA too if you want the method checked: there it must find $FFCF/$FFD0 and nothing
--      else, which is what makes a hit on the patched build trustworthy.)
--   2. Lua Console -> Script -> Open, pick this file.
--   3. PHASE 1 (5s)  STAND COMPLETELY STILL. Do not touch the d-pad.
--   4. PHASE 2 (15s) Walk LEFT and RIGHT, back and forth. Keep moving the whole phase.
--   5. PHASE 3 (15s) Walk UP and DOWN, back and forth. Keep moving the whole phase.
--      Log: ap_hram_scroll_<timestamp>.log beside this script. Console gets the summary.
--
-- Walking into a wall is fine and does not spoil a phase: the camera does not move on a bump, so
-- it costs coverage, never a false hit.

-- SYSTEM BUS, not WRAM. HRAM is not in the WRAM domain at all, and this is the same domain the
-- adapter itself reads the camera through -- so a hit here is directly usable rather than needing
-- a translation. `domain_probe.lua` established that System Bus and WRAM agree on the bank-1
-- bytes; this range only exists on the bus.
local DOMAIN = "System Bus"
local LO, HI = 0xFF80, 0xFFFE

local SAMPLE_EVERY = 2 -- frames. A camera register changes several times inside one step, so
-- sampling per step would see only its endpoints. 127 bytes every other frame is nothing.

local STILL_FRAMES = 300
local AXIS_FRAMES = 900

-- The pair the adapter is using RIGHT NOW, so the report can speak about them by name.
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
		-- Flush every 20 LINES: bounded cost, live log. A per-line flush was removed once in a
		-- buffering sweep and a probe then reported NOTHING for a whole run -- an empty log reads
		-- exactly like "nothing happened" (`pitfalls.md`).
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
	return nil -- nil, NOT 0: a read that failed must not look like a byte holding zero
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
			-- Capped so one noisy byte cannot eat memory. 40 distinct values is far more than a
			-- camera shows in a phase and far less than a frame counter does.
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

-- Distinct values seen at an address, sorted. Returned rather than printed so the caller can both
-- show them and reason about them -- a probe that returns a verdict cannot be sanity-checked.
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

-- Does this address walk a RUN, or does it just flip? A camera steps by a constant stride within a
-- phase, so its distinct values are evenly spaced. Reported as the commonest gap and how much of
-- the sequence shares it -- a number to read, not a boolean to trust.
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
	-- AN INSTRUMENT REPORTS ITS OWN COVERAGE, not only its findings.
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

	-- EVERYTHING THAT MOVED, UNFILTERED -- and this section is here because the first version of
	-- this probe did not have it (2026-08-26). The strict "moved on X ONLY" test above found the
	-- Y register cleanly and reported ZERO X candidates, which reads as "the X register is not in
	-- HRAM" and is nothing of the sort: a byte that twitched once during the up/down phase --
	-- because a walk is never perfectly axis-pure -- was discarded before anyone could look at it.
	-- `probes.md`: a filter applied before you look is a guess about the answer, and a wrong guess
	-- still produces a complete-looking result. 127 addresses is a readable dump; print them.
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

	-- THE ASSUMPTION, TESTED BY NAME. Whatever the sweep above found, these two are what the
	-- adapter is reading today, so the run has to say what they did -- otherwise a clean-looking
	-- result leaves "were the old ones right after all?" unanswered.
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

-- Runs under the dev loader (which owns the frame loop, so the adapter can stay attached and keep
-- the ghost on screen while this measures) or standalone from the Lua Console.
if MESHGHOST_DEV_LOADER then
	MESHGHOST_DEV_TICK = tick
else
	while true do
		tick()
		emu.frameadvance()
	end
end
