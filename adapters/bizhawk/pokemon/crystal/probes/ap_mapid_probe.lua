-- MeshGhost — Crystal/Archipelago: which byte pair is the CURRENT map, not the previous one
--
-- READ-ONLY. Writes nothing, spawns nothing.
--
-- WHY
-- Two state runs, intersected, left seven candidates for wMapGroup/wMapNumber -- and they disagree
-- in a way that matters. 0x1CBC/0x1CBD (the bytes sitting just before the coordinates) survived the
-- first run and not the second; 0x0D24/0x0D26 survived both.
--
-- That is exactly what a PREVIOUS-map record looks like next to the live one. Both change when you
-- change map; both are "small numbers"; both are stable while you walk. The difference only shows
-- up in WHEN they change -- a previous-map byte holds the map you just left, so it is right again
-- by the next transition and wrong in between.
--
-- It matters because the adapter uses this pair as the area id, which decides whether a peer is
-- in the same place as you. A pair that lags by one transition puts every ghost in the map you
-- both just left, for the whole map.
--
-- HOW
-- Walk through several maps and log every candidate at every transition. A transition is detected
-- without knowing any map address at all: the player COORDINATES jump by more than a tile, which
-- only happens on a load. Then read the table: the live pair changes at the same moment as the
-- jump and matches for the whole visit; the lagging pair is one row behind, and a coincidence
-- drifts within a single map.
--
-- HOW TO RUN
--   1. Load the ARCHIPELAGO Crystal ROM, be in the overworld.
--   2. Lua Console -> Script -> Open, pick this file.
--   3. WALK THROUGH AT LEAST FOUR MAPS over the next 90 seconds, and make them DIFFERENT kinds:
--      into a house, back out, along a route, into another building. Doubling back is fine and
--      actually helps -- a lagging byte gives itself away when you revisit a map.
--      Stand still for a couple of seconds after each transition.
--      Log: ap_mapid_<timestamp>.log beside this script. Console gets the transitions only.

local DOMAIN = "WRAM"
local RUN_FRAMES = 5400 -- 90 seconds
local SAMPLE_EVERY = 6

local X, Y = 0x1CBF, 0x1CBE -- MEASURED (verified.md, 2026-08-18)

-- The seven survivors of the two-run intersection, plus the two that survived only run 1. Listed
-- in address order; the probe has no favourite among them.
local WATCH = { 0x0D24, 0x0D25, 0x0D26, 0x0D4E, 0x0D4F, 0x0D71, 0x0D73, 0x1CBC, 0x1CBD }

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

local logfile = io.open(string.format("%s/ap_mapid_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")

local function log(msg)
	if logfile then
		logfile:write(msg, "\n")
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

local function row()
	local parts = {}
	for _, a in ipairs(WATCH) do
		parts[#parts + 1] = string.format("%3d", u8(a))
	end
	return table.concat(parts, " ")
end

local header = {}
for _, a in ipairs(WATCH) do
	header[#header + 1] = string.format("%04X", a)
end

say("=== MeshGhost Crystal/AP map-identity probe (READ-ONLY) ===")
say("Walk through at least four maps in the next 90 seconds. Pause a moment after each.")
log("A transition is detected from the player coordinates jumping, so no map address is assumed.")
log("")
log("event            x   y  | " .. table.concat(header, "  "))

local px, py = u8(X), u8(Y)
local prevRow = row()
local frames, transitions = 0, 0

log(string.format("%-14s %3d %3d | %s", "start", px, py, prevRow))

local function tick()
	frames = frames + 1
	if frames > RUN_FRAMES then
		return
	end
	if frames % SAMPLE_EVERY ~= 0 then
		return
	end

	local x, y = u8(X), u8(Y)
	local jumped = math.abs(x - px) > 1 or math.abs(y - py) > 1
	local now = row()

	if jumped then
		transitions = transitions + 1
		-- Log the values BEFORE and AFTER the jump on adjacent lines: a byte that is still showing
		-- the old map on the "after" line is the lagging one, and that is the whole question.
		log(string.format("%-14s %3d %3d | %s", "-- before " .. transitions, px, py, prevRow))
		say(string.format("transition %d: coordinates jumped %d,%d -> %d,%d",
			transitions, px, py, x, y))
		log(string.format("%-14s %3d %3d | %s", "-- after " .. transitions, x, y, now))
	elseif now ~= prevRow then
		-- A candidate moved WITHOUT a map change. That alone disqualifies it as map identity, so
		-- it is worth its own line rather than being folded into the next transition.
		log(string.format("%-14s %3d %3d | %s", "changed", x, y, now))
	end

	px, py, prevRow = x, y, now

	if frames == RUN_FRAMES then
		log("")
		say(string.format("Done: %d transition(s) recorded.", transitions))
		log("READ IT LIKE THIS: the live pair changes on the SAME line as the jump and then holds")
		log("for the whole visit. A previous-map byte still shows the old value on the 'after' line")
		log("and only catches up at the NEXT transition. Anything that moved on a 'changed' line")
		log("without a jump is neither.")
	end
end

while true do
	tick()
	emu.frameadvance()
end
