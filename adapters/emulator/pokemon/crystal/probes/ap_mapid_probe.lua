-- Read-only, Archipelago: which candidate byte pair is the current map, not the previous one. A transition is the
-- player's coordinates jumping more than a tile; the live pair changes on the jump, a previous-map byte one later.
-- Walk through at least four different maps in 90 seconds, pausing after each; doubling back helps.

local DOMAIN = "WRAM"
local RUN_FRAMES = 5400 -- 90 seconds
local SAMPLE_EVERY = 6

local X, Y = 0x1CBF, 0x1CBE -- the player's coordinates, measured on this build

-- The two-run intersection's seven survivors plus the two that survived only run 1, in address order.
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
		-- Flush every 20 lines: a bounded cost, and a log that is never empty for a whole run.
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
		-- Before and after the jump on adjacent lines: a byte still showing the old map after it is the lagging one.
		log(string.format("%-14s %3d %3d | %s", "-- before " .. transitions, px, py, prevRow))
		say(string.format("transition %d: coordinates jumped %d,%d -> %d,%d",
			transitions, px, py, x, y))
		log(string.format("%-14s %3d %3d | %s", "-- after " .. transitions, x, y, now))
	elseif now ~= prevRow then
		-- A candidate that moved without a map change is not the map identity.
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
