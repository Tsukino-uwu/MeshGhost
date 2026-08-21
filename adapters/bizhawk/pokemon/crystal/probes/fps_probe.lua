-- MeshGhost — Pokémon Crystal: how fast is this session actually running?
--
-- READ-ONLY, and deliberately the cheapest thing in this folder: two calls a second, no memory
-- reads at all. A probe that costs frame rate cannot be used to measure frame rate
-- (`_template/probes.md`), so this one does almost nothing.
--
-- WHY THIS EXISTS
-- The user, 2026-08-21: *"the game looks really laggy"*, then *"im still seeing a lot of lag
-- happening constantly"*. Lag has to be ISOLATED BY SUBTRACTION rather than guessed at -- the
-- session had four Lua scripts ticking every frame, any of which could be the cost, and one of
-- them is the adapter being judged. This gives each configuration a number instead of an
-- impression, so the answer is a table rather than an argument.
--
-- WHAT IT MEASURES
-- Emulated frames per wall-clock second. 60 is full speed for this game. It reports the average
-- over each second and the worst second seen, because a steady 55 and a 60 that drops to 20 twice
-- a minute feel completely different and a mean hides the second one.
--
-- HOW TO RUN
--   Add it to the loader's target file alongside whatever configuration is being measured, and
--   read fps_<timestamp>.log beside this file. Load it FIRST and leave it loaded across
--   configurations so every reading comes from the same instrument.

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/fps_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	-- Buffered, and never flushed per line: this probe MEASURES hitches, and a flush per line is
	-- itself a 63-78ms hitch on the game thread (measured 2026-08-21 -- with this script running
	-- alone, its own once-a-second log line was the only hitch in the session).
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

-- console.log appends to BizHawk's GUI console window, and that is not cheap -- the same mechanism
-- took the Emerald adapter to 1fps once (crowd-limits.md). An instrument must not produce the
-- effect it is looking for, so routine readings go to the FILE only and the console gets one line
-- in ten.
local raw_log = console.log
local lines = 0
local function log(msg)
	lines = lines + 1
	if lines <= 3 or lines % 10 == 0 then
		raw_log(msg)
	end
	if logfile then
		logfile:write(msg, "\n")
	end
end

open_log()
log("=== MeshGhost Crystal frame rate ===")
log("Emulated frames per wall-clock second. 60 is full speed. Worst second is tracked separately,")
log("because an average hides a stutter and a stutter is what gets noticed.")

local frames, lastClock, worst, reports = 0, os.clock(), nil, 0

-- CHOPPY IS NOT SLOW, and measuring the wrong one wastes a session.
--
-- The user, 2026-08-21: *"the game still feels choppy/laggy... been choppy this whole chat"* -- while
-- this probe was reporting 59.7fps. Both can be true: ten frames lost inside one second still
-- averages 58, so a per-second mean cannot see a hitch. What a person sees as chop is a frame that
-- took much longer than 16.7ms, however rare.
--
-- So the frame-to-frame gap is timed and bucketed: how many frames took longer than one frame's
-- worth, how many took longer than two, and the worst single gap. A steady 60 has none of either.
local lastFrame, slow1, slow2, worstGap = os.clock(), 0, 0, 0

local function tick()
	frames = frames + 1

	local t = os.clock()
	local gap = t - lastFrame
	lastFrame = t
	if gap > 0.033 then
		slow2 = slow2 + 1
	elseif gap > 0.020 then
		slow1 = slow1 + 1
	end
	if gap > worstGap then
		worstGap = gap
	end

	local now = t
	local elapsed = now - lastClock
	if elapsed < 1.0 then
		return
	end

	local fps = frames / elapsed
	if not worst or fps < worst then
		worst = fps
	end
	frames, lastClock = 0, now
	reports = reports + 1

	-- Every second while things are bad, every ten while they are fine: a healthy session should
	-- not fill the console, but a struggling one is exactly when a per-second reading is wanted.
	if fps < 55 or slow1 > 0 or slow2 > 0 or reports % 10 == 0 then
		log(string.format("  %.1f fps  |  hitches this second: %d over 20ms, %d over 33ms  |  "
			.. "worst gap %.1fms  (worst second: %.1f fps)",
			fps, slow1, slow2, worstGap * 1000, worst))
	end
	slow1, slow2, worstGap = 0, 0, 0

	-- One flush a minute, so a session that is watched live is never far behind, while the cost is
	-- one hitch a minute rather than one a second.
	if logfile and reports % 10 == 0 then
		pcall(function() logfile:flush() end)
	end
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
	if worst then
		log(string.format("  --- stopping. Worst second in this configuration: %.1f fps ---", worst))
	end
	if logfile then
		logfile:close()
		logfile = nil
	end
end

-- A registered callback outlives its script under BizHawk, which is why this is a loop and not
-- event.onframeend (pitfalls.md).
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
