-- Where the maps touch and where the screen ends: logs the map's connection block and the camera, and on every map
-- change a seam report (which departing struct named the arriving map; none means a warp) that runs the translation
-- backwards against the crossing to check itself. Passive: presses and writes nothing. Walk freely; every 10 s and on
-- unload it says what it has not seen. Logs beside this script, named by the loader target.

local DOMAIN = "WRAM"

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- Vanilla V1.0, from our hash-verified build's .sym. No Archipelago base is derived from a delta: a block that fails
-- its own check dumps a raw window either side instead.
local A = {
	W_MAPGROUP = flat(0xDCB5),
	W_MAPNUMBER = flat(0xDCB6),
	W_YCOORD = flat(0xDCB7),
	W_XCOORD = flat(0xDCB8),
	W_BGMAPOFFSETX = flat(0xD14C),
	W_BGMAPOFFSETY = flat(0xD14D),
	-- Our own map's size in blocks of 2x2 tiles: a connection struct carries only the neighbour's width.
	W_MAPBORDERBLOCK = flat(0xD19D),
	W_MAPHEIGHT = flat(0xD19E),
	W_MAPWIDTH = flat(0xD19F),
	W_MAPCONNECTIONS = flat(0xD1A8),
}
local H_SCX, H_SCY = 0xFFCF, 0xFFD0

-- MESHGHOST_CRYSTAL_CONN_ADDR tests a candidate block address on a build that moved it.
local CONN = tonumber(os.getenv("MESHGHOST_CRYSTAL_CONN_ADDR") or "")
	or MESHGHOST_CRYSTAL_CONN_ADDR or A.W_MAPCONNECTIONS

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
local function bus8(a)
	local ok, v = pcall(memory.read_u8, a, "System Bus")
	return (ok and v) or 0
end

local f
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	-- Named by the loader target: two instances starting in the same second would otherwise write one log.
	local who = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "solo")
		:gsub("^bizhawk%-dev%-loader%-?", ""):gsub("%.target$", "")
	if who == "" then who = "solo" end
	f = io.open(string.format("%s/connections_%s_%s.log", dir, who,
		os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, flushed on a timer: a flush costs frames on the emulator's own thread.
	if f then f:setvbuf("full", 1 << 14) end
end
local function say(s)
	if f then f:write(s .. "\n") end
end
local function shout(s)
	say(s)
	pcall(function() console.log("connections: " .. s) end)
end

-- Field names are the decomp's; what each value means is what the seam report measures.
local function readConn(d)
	return {
		grp = u8(d.at + 0), num = u8(d.at + 1),
		stripPtr = u16(d.at + 2), stripLoc = u16(d.at + 4),
		stripLen = u8(d.at + 6), width = u8(d.at + 7),
		yOff = u8(d.at + 8), xOff = u8(d.at + 9),
		window = u16(d.at + 10),
	}
end
local function connStr(c)
	return string.format("%d/%d w=%d len=%d yoff=%d xoff=%d loc=%04X ptr=%04X win=%04X",
		c.grp, c.num, c.width, c.stripLen, c.yOff, c.xOff, c.stripLoc, c.stripPtr, c.window)
end

local function snapshot()
	local s = {
		grp = u8(A.W_MAPGROUP), num = u8(A.W_MAPNUMBER),
		y = u8(A.W_YCOORD), x = u8(A.W_XCOORD),
		bgx = u8(A.W_BGMAPOFFSETX), bgy = u8(A.W_BGMAPOFFSETY),
		scx = bus8(H_SCX), scy = bus8(H_SCY),
		mw = u8(A.W_MAPWIDTH), mh = u8(A.W_MAPHEIGHT), border = u8(A.W_MAPBORDERBLOCK),
		mask = u8(CONN),
		conns = {},
	}
	for i, d in ipairs(DIRS) do s.conns[i] = readConn(d) end
	return s
end

local function areaOf(s) return s.grp .. "/" .. s.num end

-- A flagged direction with an empty struct, or the reverse, means CONN points at something else.
local function disagreement(s)
	local bad = {}
	for i, d in ipairs(DIRS) do
		local flagged = (s.mask & d.bit) ~= 0
		local populated = s.conns[i].grp ~= 0 and s.conns[i].grp < 64
		if flagged ~= populated then
			bad[#bad + 1] = string.format("%s(flag=%s struct=%d/%d)", d.name,
				tostring(flagged), s.conns[i].grp, s.conns[i].num)
		end
	end
	return bad
end

-- Dumped once, only when the block fails, and unfiltered: a filter before looking is a guess about the answer.
local dumpedWindow = false
local function dumpWindow()
	if dumpedWindow then return end
	dumpedWindow = true
	shout("the connection block failed its own consistency check -- dumping raw WRAM either side"
		.. " so the real one can be found by correlation. Re-run with"
		.. " MESHGHOST_CRYSTAL_CONN_ADDR=<addr> to test a candidate.")
	for row = CONN - 0x40, CONN + 0x60, 16 do
		local parts = {}
		for i = 0, 15 do parts[#parts + 1] = string.format("%02X", u8(row + i)) end
		say(string.format("  %04X  %s", row, table.concat(parts, " ")))
	end
end

-- The translation, checked against every crossing. Each connection has an along-axis field (the tile landed on in
-- the neighbour) and a signed cross-axis shift, swapped between west/east and north/south. c.width is always the
-- neighbour's width, so it feeds nothing; our own size comes from wMapWidth/wMapHeight. Run backwards: one tile past
-- our edge is where the player landed, so translating the landing tile must give the tile they left from.
local function signed8(v) return (v > 127) and (v - 256) or v end

local candidateOk, candidateBad = 0, 0
local function checkCandidate(dirName, from, to, c)
	local mx, my
	if dirName == "west" then
		mx, my = to.x - (c.xOff + 1), to.y - signed8(c.yOff)
	elseif dirName == "east" then
		mx, my = to.x + from.mw * 2, to.y - signed8(c.yOff)
	elseif dirName == "north" then
		mx, my = to.x - signed8(c.xOff), to.y - (c.yOff + 1)
	else
		mx, my = to.x - signed8(c.xOff), to.y + from.mh * 2
	end
	-- Compared as the game stores them: one tile off the west edge reads 255, not -1.
	local hit = (mx % 256 == from.x) and (my % 256 == from.y)
	-- A savestate load onto a connected map looks like a seam too; only a real crossing leaves from one tile outside.
	local outside = from.x == 255 or from.y == 255 or from.x >= from.mw * 2
		or from.y >= from.mh * 2
	if not outside then
		say(string.format("  CANDIDATE CHECK (%s): SKIPPED -- the player was at %d,%d, inside"
			.. " this map's own %dx%d tiles, so the map did not change by walking off an edge."
			.. " This is a savestate load or a warp, and it cannot test the formula.", dirName,
			from.x, from.y, from.mw * 2, from.mh * 2))
		return
	end
	if hit then candidateOk = candidateOk + 1 else candidateBad = candidateBad + 1 end
	say(string.format("  CANDIDATE CHECK (%s): translating the landing tile %d,%d back gives"
		.. " %d,%d (stored as %d,%d); the player actually left from %d,%d -- %s", dirName, to.x,
		to.y, mx, my, mx % 256, my % 256, from.x, from.y,
		hit and "AGREES" or "DISAGREES, the formula is wrong"))
end

local prev = nil
local frames, sinceFlush, sinceBeat = 0, 0, 0
-- Snapshots, not log lines: when the engine rewrites the block relative to the map bytes is itself measured, so the
-- report searches back for the newest snapshot still on the old map whose block named the new one.
local ring = {}
local RING = 16
local seams, warps = 0, 0
local dirSeen = { north = 0, south = 0, west = 0, east = 0 }
local blockEverWrong = false
local blockRewriteLead = nil

local function push(s)
	ring[#ring + 1] = s
	if #ring > RING then table.remove(ring, 1) end
end

local function coverage(tag)
	say("")
	say(string.format("=== coverage (%s) after %d frames ===", tag, frames))
	say(string.format("  seam crossings: %d   warps (no struct predicted it): %d", seams, warps))
	say(string.format("  directions exercised -- north %d, south %d, west %d, east %d",
		dirSeen.north, dirSeen.south, dirSeen.west, dirSeen.east))
	local missing = {}
	for _, d in ipairs({ "north", "south", "west", "east" }) do
		if dirSeen[d] == 0 then missing[#missing + 1] = d end
	end
	if #missing > 0 then
		say("  NOT YET SEEN: " .. table.concat(missing, ", ")
			.. " -- the arithmetic for these directions is unmeasured, not confirmed.")
	end
	say(string.format("  candidate arithmetic: %d crossing(s) agreed, %d disagreed", candidateOk,
		candidateBad))
	if candidateBad > 0 then
		say("  THE FORMULA IS WRONG for at least one crossing -- do not build on it. The"
			.. " disagreeing crossings are printed in full above.")
	end
	if blockRewriteLead then
		say(string.format("  the connection block was rewritten up to %d frame(s) BEFORE the map"
			.. " bytes changed -- the adapter must not read the two as one atomic sample.",
			blockRewriteLead))
	elseif seams > 0 then
		say("  the connection block and the map bytes changed on the same frame every time"
			.. " (lead 0), across every seam seen so far.")
	end
	if blockEverWrong then
		say("  WARNING: the connection block disagreed with its own bitmask at least once."
			.. " Every reading above is suspect until the address is settled.")
	end
end

shout(string.format("passive. connection block at %04X, walk seams and warps freely."
	.. " Screen mapping is logged alongside. Log: connections_*.log", CONN))
say("legend: area=group/number  pos=x,y (wXCoord/wYCoord)  bg=BGMapOffsetX/Y  cam=hSCX/hSCY")
say("        mask bits: EAST 01 WEST 02 SOUTH 04 NORTH 08")

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local s = snapshot()

	local line = string.format("f=%d area=%s pos=%d,%d bg=%d,%d cam=%d,%d dim=%dx%d(blk=%d,"
		.. "tiles %dx%d) mask=%02X", frames, areaOf(s), s.x, s.y, s.bgx, s.bgy, s.scx, s.scy,
		s.mw, s.mh, s.border, s.mw * 2, s.mh * 2, s.mask)
	s.line = line

	local changed = (not prev) or prev.x ~= s.x or prev.y ~= s.y
		or areaOf(prev) ~= areaOf(s) or prev.mask ~= s.mask
	if changed then say(line) end

	if not prev or areaOf(prev) ~= areaOf(s) then
		if prev then
			-- The frames leading in show which coordinate jumped, and by how much.
			say("")
			say(string.format("=== MAP CHANGE at f=%d: %s -> %s ===", frames, areaOf(prev),
				areaOf(s)))
			say("  the sixteen frames leading in:")
			for _, r in ipairs(ring) do say("    " .. r.line) end
			say("    " .. line .. "   <- the frame the map bytes changed")
			-- How far back that snapshot sits is how far the block's rewrite leads the map bytes.
			local predicted, from, back, dirIdx = nil, nil, nil, nil
			for k = #ring, 1, -1 do
				local cand = ring[k]
				if areaOf(cand) == areaOf(prev) then
					for i, d in ipairs(DIRS) do
						local c = cand.conns[i]
						if c.grp == s.grp and c.num == s.num and (cand.mask & d.bit) ~= 0 then
							predicted, from, back, dirIdx = d.name, cand, #ring - k, i
							break
						end
					end
				end
				if predicted then break end
			end
			if predicted then
				seams = seams + 1
				dirSeen[predicted] = dirSeen[predicted] + 1
				local c = from.conns[dirIdx]
				say(string.format("  PREDICTED BY THE %s CONNECTION: %s", predicted:upper(),
					connStr(c)))
				say(string.format("  the block named it %d frame(s) before the map bytes changed",
					back))
				if back > 0 then
					blockRewriteLead = math.max(blockRewriteLead or 0, back)
				end
				say(string.format("  player %d,%d on %s  ->  %d,%d on %s", from.x, from.y,
					areaOf(from), s.x, s.y, areaOf(s)))
				say(string.format("  raw deltas: dx=%d dy=%d  (against yoff=%d xoff=%d"
					.. " width=%d len=%d) -- the arithmetic to be derived, NOT assumed",
					s.x - from.x, s.y - from.y, c.yOff, c.xOff, c.width, c.stripLen))
				checkCandidate(predicted, from, s, c)
			else
				warps = warps + 1
				say("  NO connection struct named this map -- this was a WARP (a door, a cave"
					.. " mouth, a fly). Peers on the far side of a warp stay hidden, which is"
					.. " the behaviour we want; recorded so warps and seams can be told apart.")
				say(string.format("  the departing map's connections were mask=%02X:", prev.mask))
				for i, d in ipairs(DIRS) do
					say(string.format("    %-5s %s", d.name, connStr(prev.conns[i])))
				end
			end
			say("  the NEW map's own connections, mask=" .. string.format("%02X", s.mask) .. ":")
			for i, d in ipairs(DIRS) do
				say(string.format("    %-5s %s", d.name, connStr(s.conns[i])))
			end
			say("")
		else
			say("")
			say(string.format("=== first map seen: %s, mask=%02X ===", areaOf(s), s.mask))
			for i, d in ipairs(DIRS) do
				say(string.format("    %-5s %s", d.name, connStr(s.conns[i])))
			end
			say("")
		end
		local bad = disagreement(s)
		if #bad > 0 then
			blockEverWrong = true
			say("  BITMASK/STRUCT DISAGREEMENT: " .. table.concat(bad, " "))
			dumpWindow()
		end
	end

	prev = s
	push(s)

	sinceBeat = sinceBeat + 1
	if sinceBeat >= 600 then
		sinceBeat = 0
		say("heartbeat: " .. line)
		coverage("heartbeat")
	end

	sinceFlush = sinceFlush + 1
	if sinceFlush >= 120 then
		sinceFlush = 0
		if f then f:flush() end
	end
end

MESHGHOST_DEV_UNLOAD = function()
	coverage("unload")
	if f then f:flush(); f:close(); f = nil end
end
