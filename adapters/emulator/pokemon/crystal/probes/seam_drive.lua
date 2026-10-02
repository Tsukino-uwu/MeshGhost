-- Drives the Olivine City <-> Route 40 seam both ways from savestates 7 and 8, then Route 40 <-> Route 41 down and up
-- from slot 5 (on the water with Surf up, so a battle aborts the run): crossing a seam both ways overdetermines its
-- arithmetic. Input-driving; records what the game did and derives nothing (connections_probe.lua beside it has the
-- struct detail). Ends by reloading slot 8 and checking where it lands. Unload it before judging anything on screen.

local DOMAIN = "WRAM"
local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

local W_MAPGROUP, W_MAPNUMBER = flat(0xDCB5), flat(0xDCB6)
local W_YCOORD, W_XCOORD = flat(0xDCB7), flat(0xDCB8)
local W_BGX, W_BGY = flat(0xD14C), flat(0xD14D)
local CONN = flat(0xD1A8)
-- Direction bits from the decompilation, struct addresses from the .sym; connections_probe.lua checks both.
local DIRS = {
	{ name = "north", bit = 0x08, at = CONN + 1 },
	{ name = "south", bit = 0x04, at = CONN + 13 },
	{ name = "west", bit = 0x02, at = CONN + 25 },
	{ name = "east", bit = 0x01, at = CONN + 37 },
}

local function u8(a)
	local ok, v = pcall(memory.read_u8, a, DOMAIN)
	return (ok and v) or 0
end
local function u16(a)
	local ok, v = pcall(memory.read_u16_le, a, DOMAIN)
	return (ok and v) or 0
end

local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	f = io.open(string.format("%s/seam_drive_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	if f then f:setvbuf("full", 1 << 13) end
end
local function say(s)
	if f then f:write(s .. "\n") end
end
local function shout(s)
	say(s)
	pcall(function() console.log("seam_drive: " .. s) end)
end

local function readState()
	local s = {
		grp = u8(W_MAPGROUP), num = u8(W_MAPNUMBER),
		y = u8(W_YCOORD), x = u8(W_XCOORD),
		bgx = u8(W_BGX), bgy = u8(W_BGY),
		mask = u8(CONN), conns = {},
	}
	for i, d in ipairs(DIRS) do
		s.conns[i] = {
			grp = u8(d.at + 0), num = u8(d.at + 1),
			stripPtr = u16(d.at + 2), stripLoc = u16(d.at + 4),
			stripLen = u8(d.at + 6), width = u8(d.at + 7),
			yOff = u8(d.at + 8), xOff = u8(d.at + 9),
			window = u16(d.at + 10),
		}
	end
	return s
end
local function areaOf(s) return s.grp .. "/" .. s.num end
local function posOf(s) return string.format("%d,%d", s.x, s.y) end

-- Only the directions the bitmask claims are live: an unflagged struct still holds the previous map's values.
local function dumpConns(s, indent)
	say(string.format("%smask=%02X", indent, s.mask))
	for i, d in ipairs(DIRS) do
		local c = s.conns[i]
		local live = (s.mask & d.bit) ~= 0
		say(string.format("%s  %-5s %s %d/%d w=%d len=%d yoff=%d xoff=%d loc=%04X ptr=%04X"
			.. " win=%04X", indent, d.name, live and "LIVE " or "stale", c.grp, c.num, c.width,
			c.stripLen, c.yOff, c.xOff, c.stripLoc, c.stripPtr, c.window))
	end
end

-- slot = nil carries on from the previous crossing: Down then Up crosses slot 5's seam both ways from one load,
-- spending as few frames on the water as it can.
local STEPS = {
	{ slot = 7, press = "Left", expect = "Route 40 (west of the seam)" },
	{ slot = 8, press = "Right", expect = "Olivine City (east of the seam)" },
	{ slot = 5, press = "Down", expect = "Route 41 (south of the seam)" },
	{ press = "Up", expect = "Route 40 again (north of the seam)" },
}
local W_BATTLEMODE = flat(0xD22D)

local phase, n, step = "start", 0, 0
local before, after, lastBefore = nil, nil, nil
local slot8First = nil
local results = {}

local function report(i, b, a)
	local sp = STEPS[i]
	say("")
	-- sp.slot is nil for a carried-over crossing, and %d on nil would take the run down at the report.
	say(string.format("=== CROSSING %d: %s, pressed %s, expected %s ===", i,
		sp.slot and ("slot " .. sp.slot) or "carried over from the previous crossing",
		sp.press, sp.expect))
	say(string.format("  BEFORE (the last frame before the map changed, NOT the load position)"
		.. " area=%s pos=%s bg=%d,%d", areaOf(b), posOf(b), b.bgx, b.bgy))
	dumpConns(b, "    ")
	say(string.format("  AFTER   area=%s pos=%s bg=%d,%d", areaOf(a), posOf(a), a.bgx, a.bgy))
	dumpConns(a, "    ")
	-- Which of the departing map's live connections named the destination, stated rather than assumed from the press.
	local named = nil
	for j, d in ipairs(DIRS) do
		local c = b.conns[j]
		if (b.mask & d.bit) ~= 0 and c.grp == a.grp and c.num == a.num then
			named = d
			say(string.format("  the departing map's %s connection named this destination:"
				.. " yoff=%d xoff=%d width=%d len=%d", d.name, c.yOff, c.xOff, c.width,
				c.stripLen))
			break
		end
	end
	if not named then
		say("  NO live connection on the departing map named this destination -- either this was"
			.. " a warp rather than a seam, or the block is not what we think it is. The"
			.. " arithmetic cannot be derived from this crossing.")
	end
	say(string.format("  raw deltas: dx=%d dy=%d", a.x - b.x, a.y - b.y))
	results[i] = { b = b, a = a, named = named and named.name or nil }
end

shout("driving slot 7 (walk left into Route 40), then slot 8 (walk right into Olivine City)."
	.. " Hands off the controller until it says DONE.")

MESHGHOST_DEV_TICK = function()
	n = n + 1

	if phase == "start" then
		if n >= 30 then
			step, phase, n = 1, "load", 0
		end
		return
	end

	if phase == "load" then
		if n == 1 then
			if STEPS[step].slot then
				shout(string.format("crossing %d: loading slot %d", step, STEPS[step].slot))
				pcall(savestate.loadslot, STEPS[step].slot)
			else
				shout(string.format("crossing %d: continuing from where crossing %d left off",
					step, step - 1))
			end
		elseif n >= 90 then
			-- After the load has settled: for the first frames the engine is still mid-rebuild.
			before = readState()
			lastBefore = before
			if STEPS[step].slot == 8 and not slot8First then slot8First = before end
			shout(string.format("  settled on area=%s pos=%s -- pressing %s", areaOf(before),
				posOf(before), STEPS[step].press))
			phase, n = "walk", 0
		end
		return
	end

	if phase == "walk" then
		local now = readState()
		-- A battle aborts the run: a direction held into a battle menu presses buttons at the game.
		if u8(W_BATTLEMODE) ~= 0 then
			shout(string.format("  crossing %d: a battle started mid-crossing (wBattleMode=%d)."
				.. " Stopping here rather than pressing into it -- reload and re-run.", step,
				u8(W_BATTLEMODE)))
			say(string.format("  crossing %d ABORTED: battle. Nothing measured for this"
				.. " direction.", step))
			phase = "done"
			if f then f:flush() end
			return
		end
		if areaOf(now) ~= areaOf(before) then
			after = now
			phase, n = "settle", 0
			return
		end
		-- The frame before the change is the reading: the swap happens one tile outside the map's bounds.
		lastBefore = now
		if n >= 240 then
			-- Reported, not retried: a silent retry would hide a savestate that is not where this expects.
			shout(string.format("  crossing %d: held %s for 240 frames and the map never changed"
				.. " (still area=%s pos=%s). The savestate may not be one tile from the seam.",
				step, STEPS[step].press, areaOf(now), posOf(now)))
			after = now
			phase, n = "settle", 0
			return
		end
		pcall(joypad.set, { [STEPS[step].press] = true })
		pcall(joypad.set, { [STEPS[step].press] = true }, 1)
		return
	end

	if phase == "settle" then
		-- Let the arriving map finish loading: the connection block belongs to the settled map.
		if n >= 90 then
			after = readState()
			report(step, lastBefore or before, after)
			if step < #STEPS then
				step, phase, n = step + 1, "load", 0
			else
				phase, n = "restore", 0
			end
		end
		return
	end

	if phase == "restore" then
		if n == 1 then
			pcall(savestate.loadslot, 8)
		elseif n >= 90 then
			local back = readState()
			say("")
			say("=== returning to a known state ===")
			if slot8First then
				local same = areaOf(back) == areaOf(slot8First) and back.x == slot8First.x
					and back.y == slot8First.y
				say(string.format("  reloaded slot 8: area=%s pos=%s (first load read area=%s"
					.. " pos=%s) -- %s", areaOf(back), posOf(back), areaOf(slot8First),
					posOf(slot8First), same and "MATCH" or "MISMATCH, do not trust the run"))
			else
				say(string.format("  reloaded slot 8: area=%s pos=%s (never read on the way in,"
					.. " so there is nothing to compare it against)", areaOf(back), posOf(back)))
			end
			say("")
			say("=== coverage ===")
			for i = 1, #STEPS do
				local r = results[i]
				if r then
					say(string.format("  crossing %d (%s): %s -> %s via the %s connection", i,
						STEPS[i].press, areaOf(r.b), areaOf(r.a), r.named or "NO connection"))
				else
					say(string.format("  crossing %d (%s): never completed", i, STEPS[i].press))
				end
			end
			say("  Only the west/east pair of this one seam was exercised. North and south are"
				.. " unmeasured, and a north/south arithmetic derived from these numbers would be"
				.. " a guess.")
			shout("DONE. UNLOAD THIS PROBE before judging anything on screen.")
			phase = "done"
			if f then f:flush() end
		end
		return
	end

	if phase == "done" and n % 300 == 0 and f then f:flush() end
end

MESHGHOST_DEV_UNLOAD = function()
	if f then f:flush(); f:close(); f = nil end
end
