-- MeshGhost — Pokémon Crystal: how many frames late does the painted tier come back?
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, spawns nothing, changes nothing on screen.
--
-- WHY THIS EXISTS
-- The user, 2026-08-22, after the hold was resequenced: *"think its a bit better now, but the
-- drawn ghost still appear a tiny bit late when going 'inside'"* — and, about the other
-- direction, *"i can't really tell visually when going 'outside'"*. That second sentence is a
-- measurement result, not a shrug (`_template/probes.md`, "when a human says they cannot tell,
-- that is data"): the effect is at the edge of perception, so it gets counted rather than looked
-- at again. This probe counts it, in both directions, so neither rests on eyesight.
--
-- WHAT THE ADAPTER ACTUALLY DOES, and why a frame count is the whole question.
-- The painted tier may not paint over a rebuilt world, so `drawOverflow` refuses on two separate
-- conditions and resumes when BOTH have cleared:
--
--   * `inPlay()`   -- wMapStatus back to MAPSTATUS_HANDLE. Anchored on the game's own state.
--   * the HOLD     -- a fixed SETTLE_FRAMES countdown armed when `areaId()` changes.
--
-- So the first painted frame is `max(readyFrame, areaChangeFrame + SETTLE_FRAMES)`, and the
-- lateness the user can see is that value minus `readyFrame` — the frames the tier stayed blank
-- after the game itself was ready. The two anchors fire at DIFFERENT moments (the map id changes
-- part-way through the crossing, while status is still ENTER), which is exactly why the hold's
-- length is not the same thing as the delay it produces.
--
-- WHAT IT REPORTS, per crossing, and the point is the last three columns:
--
--   * `ready-cross`    -- how long the crossing itself took, the part nobody can shorten.
--   * `hold left`      -- frames of hold still owed at the moment the game was ready. THIS IS THE
--                         LATENESS, and it is the number to drive to zero.
--   * `would be`       -- what that lateness WOULD have been under each candidate anchor, scored
--                         against the same crossing. Logging what a proposed gate would have
--                         decided, beside the raw values, is what produced both of this adapter's
--                         earlier gate corrections (`phase9.md`) — neither was visible by
--                         reasoning about the code.
--
-- The candidates, and each is a different claim about WHICH EVENT the fade-in hangs off:
--
--   A  area change + 30   -- what ships today.
--   B  ready + 0          -- no hold at all: paint the moment the game is back. If the fade is
--                            already covered by the other gates this is correct and free, and the
--                            hold is dead weight. Reported so the honest zero is on the table.
--   C  ready + 8 / 16     -- anchor the hold on the world coming BACK rather than on the map id
--                            changing, so it covers the fade-in itself instead of spending most
--                            of its frames before the fade begins.
--
-- WHICH OF THOSE IS RIGHT IS NOT SOMETHING THIS PROBE DECIDES. It measures the cost of each; a
-- hold that is too short paints over a fade, and only the user can see that. The probe writes the
-- numbers, the screen settles the choice.
--
-- HOW TO RUN
--   Load it beside the adapter. Walk in and out of a door a few times — no timing to hit, no
--   window to catch, and a slow crossing costs nothing. `probes/door_loop.lua` drives crossings
--   on its own if it is loaded, in which case this needs nobody at all.
--   Log: paintgate_<timestamp>.log beside this file.

local DOMAIN = "WRAM"

-- MIRRORS THE ADAPTER, and is printed at startup so it cannot drift silently. If
-- `playerHistory.settle` in meshghost_crystal.lua stops being 30, every "would be" column here is
-- quietly answering a question about a build that no longer exists — which is the shape of every
-- stale-instrument entry in `pitfalls.md`. Change both, or trust neither.
local SETTLE_FRAMES = 30

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- Vanilla V1.0, the adapter's own vanilla table. Vanilla only on purpose: this is a question
-- about frame counts within one session, and a patched build would add a variable for no gain.
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

-- The file is the record; the console is a glance. ONE console line a second was measured at
-- 63-83ms on the emulator's own thread (`pitfalls.md`, 2026-08-21), so the headline lines are
-- capped and everything else only ever reaches the file.
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

	-- The crossing STARTS when status leaves HANDLE, which is before the map id moves. Recorded
	-- only for context: nothing can shorten the crossing itself, and reporting it beside the
	-- lateness is what stops a 5-frame gate delay being read as a 40-frame one.
	if prevStatus == MAPSTATUS_HANDLE and status ~= MAPSTATUS_HANDLE then
		pending = { leftAt = frames, from = map }
	end

	-- ARM ON THE SAME EVENT THE ADAPTER ARMS ON. `areaId()` is derived from these two bytes, so
	-- this fires on exactly the frame the adapter's own `area ~= lastArea` does -- the probe is
	-- not modelling the adapter, it is reading the same input.
	if prevMap and map ~= prevMap then
		pending = pending or { leftAt = frames, from = prevMap }
		pending.changedAt = frames
		pending.to = map
		log(string.format("  f=%-7d map %s -> %s (status=%d) -- hold armed, expires f=%d",
			frames, prevMap, map, status, frames + SETTLE_FRAMES))
	end

	-- CLOSED when the game says the world is back. That is the moment the tier could paint if
	-- nothing else were holding it, so every candidate below is scored from here.
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
		-- What each candidate anchor would have cost on THIS crossing. Same crossing, same
		-- numbers, so the columns are comparable rather than each being its own experiment.
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

-- Opened directly rather than through the loader, it needs its own frame loop -- but a loop of its
-- own inside the loader would never return and would freeze every other script in the shared
-- environment (`pitfalls.md`, 2026-08-19). So it runs one or the other, never both.
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
