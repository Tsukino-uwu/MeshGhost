-- WHERE THE MAPS TOUCH, AND WHERE THE SCREEN ENDS -- the two measurements cross-map ghosts and
-- off-screen culling both need, taken together because they read the same six bytes. 2026-08-27.
--
-- PASSIVE. It presses nothing and writes nothing to game memory. Safe to leave loaded beside the
-- adapter; safe to judge the screen with it running.
--
-- WHY IT EXISTS. Crystal has never had cross-map ghosts (Emerald's `xmapTranslate`). A peer whose
-- `area_id` is not byte-equal to ours is hidden in both tiers, so walking between two connected
-- routes makes everyone vanish at the seam. Emerald had to scan 16MB of ROM to self-locate
-- `gMapGroups`; Crystal decodes the CURRENT map's four connections straight into WRAM on every
-- map load, so the whole table is sitting at a fixed address -- IF this build has not moved it.
-- That "if" is the first thing the probe checks and the reason it does not simply trust the label.
--
-- STRUCTURE, from the decompilation (pokecrystal `macros/ram.asm`'s `map_connection_struct`,
-- addresses from our own hash-verified build's `pokecrystal.sym`):
--
--   wMapConnections        $D1A8   a bitmask: EAST 0x01, WEST 0x02, SOUTH 0x04, NORTH 0x08
--                                  (`constants/map_data_constants.asm`, shift_const order)
--   wNorthMapConnection    $D1A9   12 bytes, then South $D1B5, West $D1C1, East $D1CD
--     +0 ConnectedMapGroup   +1 ConnectedMapNumber   +2 StripPointer(2)  +4 StripLocation(2)
--     +6 StripLength         +7 ConnectedMapWidth    +8 StripYOffset     +9 StripXOffset
--     +10 Window(2)
--
-- The field names are the decomp's. What each one MEANS for seam arithmetic is NOT assumed from
-- the name -- that is the whole point of the seam report below.
--
-- HOW IT ANSWERS THE FIRST QUESTION, and how it checks itself. Every frame it reads the bitmask
-- and all four structs. When the map changes it prints a SEAM REPORT: the map we left, the map we
-- arrived on, WHICH of the old map's four structs named that map, and the player's coordinates on
-- both sides. A struct that correctly predicted the destination is the block proving it is really
-- the connection block on this build -- a self-verification no label can give. A map change no
-- struct predicted is a WARP (a door, a cave mouth), which is the other thing worth knowing: the
-- rule "translate connected maps, hide everyone else" is what makes routes visible and houses
-- hidden with no house special-case, so the probe has to be able to tell them apart.
--
-- The coordinates on both sides of a seam are the offset arithmetic. Crystal's map grid is in
-- BLOCKS of 2x2 tiles while objects live in tiles, so the sign AND the scale of every offset here
-- are open questions this probe answers with numbers rather than closing with a guess.
--
-- HOW IT ANSWERS THE SECOND QUESTION (off-screen culling: spawn a peer only just before the screen
-- could show it). The observable is the mapping from a peer's map coordinates to the screen, which
-- is the player's own coordinates plus the camera. It logs `wXCoord`/`wYCoord`, `wBGMapOffsetX/Y`
-- and `hSCX`/`hSCY` in the same line, so the visible rectangle can be derived from real numbers on
-- a real map instead of from "the screen is 20x18 tiles so it must be +-4".
--
-- ENDURANCE, NOT TIMING. There are no phases and no window to hit. Load it, walk around, cross
-- every seam you feel like crossing, walk into a house and back out. Everything is change-driven,
-- so standing still costs one line every ten seconds and nothing else.
--
-- COVERAGE. On unload -- and every 10s -- it says what it saw AND what it did not: how many seam
-- crossings, how many warps, which of the four directions have been exercised, and whether the
-- block ever looked wrong. An instrument that reports only its findings is hiding its gaps.
--
-- Log beside this script.

local DOMAIN = "WRAM"

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- VANILLA V1.0 addresses. The Archipelago build moved the coordinate block +7 and the object
-- array +6 by MEASUREMENT, and no third relationship has ever held on it -- so this probe does
-- NOT compute an Archipelago base from a delta. Instead, when the connection block fails its own
-- prediction test, it dumps a raw window either side and lets correlation find the real one.
local A = {
	W_MAPGROUP = flat(0xDCB5),
	W_MAPNUMBER = flat(0xDCB6),
	W_YCOORD = flat(0xDCB7),
	W_XCOORD = flat(0xDCB8),
	W_BGMAPOFFSETX = flat(0xD14C),
	W_BGMAPOFFSETY = flat(0xD14D),
	-- OUR OWN map's dimensions, in BLOCKS (a block is 2x2 tiles, while objects live in tiles).
	-- Needed because a connection struct carries the NEIGHBOUR's width, never ours -- so an EAST
	-- neighbour's peers can only be placed once our own width is known. $D19D-$D19F sit directly
	-- in front of the connection block; the whole map-geometry region is contiguous.
	W_MAPBORDERBLOCK = flat(0xD19D),
	W_MAPHEIGHT = flat(0xD19E),
	W_MAPWIDTH = flat(0xD19F),
	W_MAPCONNECTIONS = flat(0xD1A8),
}
local H_SCX, H_SCY = 0xFFCF, 0xFFD0

-- MESHGHOST_CRYSTAL_CONN_ADDR overrides the connection block for a build that moved it, so the
-- same probe can confirm a candidate address without being edited.
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
	-- THE INSTANCE NAME IS IN THE FILENAME. Two emulators are open for this work and both load
	-- this probe; a timestamp alone collides when they start in the same second, and the result is
	-- one truncated log rather than two, which reads as "the second instance never ran".
	local who = (os.getenv("MESHGHOST_DEV_LOADER_TARGET") or "solo")
		:gsub("^bizhawk%-dev%-loader%-?", ""):gsub("%.target$", "")
	if who == "" then who = "solo" end
	f = io.open(string.format("%s/connections_%s_%s.log", dir, who,
		os.date("%Y%m%d_%H%M%S")), "w")
	-- BUFFERED, flushed on a timer. One console.log plus one flush was measured at 63-83ms on
	-- 2026-08-21 -- four to five frames on the emulator's own thread (adapters/emulator/CLAUDE.md).
	if f then f:setvbuf("full", 1 << 14) end
end
local function say(s)
	if f then f:write(s .. "\n") end
end
local function shout(s)
	say(s)
	pcall(function() console.log("connections: " .. s) end)
end

-- One connection struct, read whole. Field names are the decomp's; the VALUES are what matters.
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

-- THE BITMASK AND THE STRUCTS MUST AGREE, and when they do not the block is not where we think.
-- A struct is "populated" if it names a plausible map group at all; a flagged direction with an
-- empty struct (or the reverse) is the signal that CONN points at something else entirely.
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

-- The raw bytes either side of CONN, for the build where the label is wrong. Dumped ONLY when the
-- block fails, and once, because 96 bytes a frame is exactly the shape this project keeps warning
-- about. Filtering before looking is a guess about the answer, so this dumps the whole window.
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

-- THE CANDIDATE ARITHMETIC, CHECKED BY THE INSTRUMENT RATHER THAN BY ME.
--
-- Derived from the east/west pair of the Olivine City <-> Route 40 seam, 2026-08-27. Stated here
-- so every later crossing tests it automatically: a formula that fits the two crossings it was
-- built from proves nothing, and the north/south form below is the MIRROR of the measured one,
-- which makes it a guess until a north or south crossing agrees with it.
--
-- The map we are on translates a peer standing on a CONNECTED neighbour into our own tile frame.
-- `c.width` is the NEIGHBOUR's width in blocks; our own dimensions come from wMapWidth/wMapHeight.
-- A block is 2x2 tiles, so every dimension doubles before it meets a coordinate.
--
-- Each connection has an ALONG-axis field and a CROSS-axis field, and which is which flips with
-- the axis: for west/east it is xoff/yoff, for north/south it is yoff/xoff.
--
--   * the CROSS-axis field is a signed shift along the seam, subtracted.
--   * the ALONG-axis field is the coordinate you LAND on in the neighbour -- 0 coming from the
--     east or south, and (neighbourExtent - 1) coming from the west or north. So the negative
--     directions get the neighbour's extent from it as `off + 1`, and the positive directions
--     need our own, which wMapWidth/wMapHeight supply.
--
--   west  neighbour:  myX = nX - (xoff + 1)     myY = nY - signed8(yoff)
--   east  neighbour:  myX = nX + ourWidthTiles  myY = nY - signed8(yoff)
--   north neighbour:  myY = nY - (yoff + 1)     myX = nX - signed8(xoff)
--   south neighbour:  myY = nY + ourHeightTiles myX = nX - signed8(xoff)
--
-- `ConnectedMapWidth` is NOT used, and that is deliberate. It is always the neighbour's WIDTH, so
-- on the vertical axis it answers the wrong question -- the north form built on it computed a
-- landing 16 tiles out and this check caught it (2026-08-27). It survives in the log lines for
-- reference and feeds nothing.
--
-- The check runs it BACKWARDS against the player's own crossing: the player standing one tile past
-- our edge is the same physical place as where they landed on the neighbour, so translating the
-- landing coordinates must reproduce the coordinates they left from.
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
	-- COMPARE AS THE GAME STORES THEM. wXCoord/wYCoord are unsigned bytes, so the tile one step
	-- off the west edge reads 255, not -1 -- and comparing a signed result against that reported
	-- the correct formula as wrong on its first two crossings (2026-08-27).
	local hit = (mx % 256 == from.x) and (my % 256 == from.y)
	-- A SAVESTATE LOAD IS NOT A CROSSING. Loading a state on a connected map changes the map bytes
	-- and the connection block will happily name the destination, so it arrives here looking like
	-- a seam -- and it drags the formula's score down with a comparison that was never valid. A
	-- real crossing has the player exactly one tile OUTSIDE our own bounds on the departing frame;
	-- a state load puts them somewhere in the middle of the map.
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
	-- The north/south forms are a mirror of the measured east/west pair and nothing has confirmed
	-- them. Saying so at the moment of the reading is the difference between a measurement and an
	-- assumption that later gets quoted as one.
end

local prev = nil
local frames, sinceFlush, sinceBeat = 0, 0, 0
-- A ring of SNAPSHOTS, not of log lines. The seam report needs the departing map's connection
-- structs, and "the frame before the map bytes changed" is an assumption about WHEN the engine
-- rewrites the block -- which is one of the things being measured. So the report searches
-- backwards for the newest snapshot that still had the old map AND named the new one, and reports
-- how many frames back that was. If the answer is ever more than one, the assumption was wrong
-- and the adapter must not make it either.
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
			-- THE SEAM REPORT. The window either side is what makes it interpretable: a single
			-- "we are now on map X" line cannot show which coordinate jumped or by how much.
			say("")
			say(string.format("=== MAP CHANGE at f=%d: %s -> %s ===", frames, areaOf(prev),
				areaOf(s)))
			say("  the sixteen frames leading in:")
			for _, r in ipairs(ring) do say("    " .. r.line) end
			say("    " .. line .. "   <- the frame the map bytes changed")
			-- Search BACKWARDS through the ring for the newest snapshot that still reported the
			-- old map and whose connection block already named the new one. That snapshot is the
			-- departing map's block; how far back it sits is how many frames the engine rewrites
			-- the block ahead of the map bytes, which is a fact the adapter will need.
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
