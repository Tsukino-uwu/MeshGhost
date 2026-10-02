-- Read-only: how many frames late the painted tier comes back after a map crossing. It paints once wMapStatus is
-- HANDLE and a SETTLE_FRAMES hold armed on the area change has run out; the map id changes mid-crossing, so the hold's
-- length is not the delay. Logs each crossing's length, the hold still owed when the game was ready, and what anchors
-- A-C would have cost. Walk through a door a few times, or load door_loop.lua beside it.

local DOMAIN = "WRAM"

-- Mirrors the adapter's playerHistory.settle, and is printed at startup: change both, or trust neither.
local SETTLE_FRAMES = 30

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- Vanilla V1.0, the adapter's own table: a patched build would add a variable for no gain.
local W_MAPSTATUS = flat(0xD432)
local W_MAPGROUP, W_MAPNUMBER = flat(0xDCB5), flat(0xDCB6)
local MAPSTATUS_HANDLE = 2

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/paintgate_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- The file is the record; the console gets the first twelve lines only.
local rawConsole, consoleLines = console.log, 0
local function say(msg)
	consoleLines = consoleLines + 1
	if consoleLines <= 12 then
		rawConsole(msg)
	end
	if logfile then
		logfile:write(msg, "\n")
	end
end

local function log(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

local function u8(a)
	local ok, v = pcall(memory.read_u8, a, DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

open_log()
say("=== MeshGhost Crystal paint-gate timing (READ-ONLY) ===")
say(string.format("mirroring the adapter's hold of %d frames, armed on the area change.",
	SETTLE_FRAMES))
say("Walk in and out of a door a few times. One row per crossing; the 'hold left' column is")
say("the lateness the user can see. No timing to hit.")

local frames = 0
local prevMap, prevStatus = nil, nil
-- The crossing in progress: armed when the map id changes, closed when status returns to HANDLE.
local pending = nil
local crossings, flushAt = 0, 0

local function tick()
	frames = frames + 1

	local status = u8(W_MAPSTATUS)
	local g, n = u8(W_MAPGROUP), u8(W_MAPNUMBER)
	if not status or not g or not n then
		return
	end
	local map = string.format("%d/%d", g, n)

	-- The crossing starts when status leaves HANDLE, before the map id moves; its length is logged beside the lateness.
	if prevStatus == MAPSTATUS_HANDLE and status ~= MAPSTATUS_HANDLE then
		pending = { leftAt = frames, from = map }
	end

	-- Armed on the same event the adapter arms on: areaId() is derived from these two bytes.
	if prevMap and map ~= prevMap then
		pending = pending or { leftAt = frames, from = prevMap }
		pending.changedAt = frames
		pending.to = map
		log(string.format("  f=%-7d map %s -> %s (status=%d) -- hold armed, expires f=%d",
			frames, prevMap, map, status, frames + SETTLE_FRAMES))
	end

	-- Closed when the game says the world is back: every candidate is scored from here.
	if pending and pending.changedAt and status == MAPSTATUS_HANDLE
		and prevStatus ~= MAPSTATUS_HANDLE then
		local ready = frames
		local expiry = pending.changedAt + SETTLE_FRAMES
		-- max(), not a sum: the two gates are independent and the tier waits for the later one.
		local firstPaint = expiry > ready and expiry or ready
		local late = firstPaint - ready

		crossings = crossings + 1
		log(string.format("  f=%-7d status back to HANDLE -- ready", frames))
		say(string.format(
			"crossing %d: %s -> %s | crossing %d frames | ready f=%d | hold expires f=%d "
			.. "| FIRST PAINT f=%d | LATE BY %d frames",
			crossings, pending.from or "?", pending.to or "?", ready - (pending.leftAt or ready),
			ready, expiry, firstPaint, late))
		-- What each candidate anchor would have cost on this same crossing.
		say(string.format(
			"             would be: A area+%d = %d late (ships today) | B ready+0 = 0 late "
			.. "| C ready+8 = 8 late | C ready+16 = 16 late",
			SETTLE_FRAMES, late))
		say(string.format(
			"             (the hold spent %d of its %d frames BEFORE the game was ready, "
			.. "i.e. before the fade-in it exists to cover)",
			(ready - pending.changedAt) < SETTLE_FRAMES and (ready - pending.changedAt)
				or SETTLE_FRAMES,
			SETTLE_FRAMES))
		pending = nil
	end

	prevMap, prevStatus = map, status

	-- Flush on a timer, never per line.
	if logfile and frames - flushAt >= 300 then
		flushAt = frames
		pcall(function() logfile:flush() end)
	end
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
	pcall(function()
		if logfile then
			logfile:flush()
			logfile:close()
			logfile = nil
		end
	end)
end

-- Its own frame loop only when opened directly: inside the loader a loop never returns and freezes the rest.
if not MESHGHOST_DEV_LOADER then
	event.onexit(function()
		pcall(function()
			if logfile then
				logfile:flush()
				logfile:close()
			end
		end)
	end)
	while true do
		tick()
		emu.frameadvance()
	end
end
