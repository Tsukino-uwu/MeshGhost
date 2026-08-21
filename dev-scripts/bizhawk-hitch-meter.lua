-- MeshGhost — BizHawk hitch meter (DEVELOPMENT TOOL, never shipped, game-agnostic)
--
-- READ-ONLY. No memory reads, no writes, no drawing. Two calls a frame and one buffered log line
-- a second, because an instrument that costs frame time cannot measure frame time.
--
-- WHY THIS EXISTS, AND WHY IT IS STANDING RIG RATHER THAN A ONE-OFF
--
-- On 2026-08-21 the user reported a Crystal session as *"choppy/laggy"* and repeated it for most of
-- an hour while every measurement said the game was running at 59.7fps. Both were true, and the
-- disagreement was the measurement's fault:
--
--   **Frame RATE is an average, and an average cannot see a hitch.** Ten frames lost inside one
--   second still reads as 58fps. What a person sees as chop is one frame that took far longer than
--   16.7ms, however rare -- and nothing in this repo was measuring that.
--
-- Measuring the frame-to-frame GAP found the cause in minutes, and found it in the instrumentation
-- itself: a script whose only per-second work was writing one log line produced exactly one 63-83ms
-- stall every second. `console.log` appends to BizHawk's GUI console window, and every write was
-- followed by a flush -- both synchronous, both on the emulator's own thread. Buffering the file and
-- throttling the console took the same configuration to 0 hitches and a 17ms worst gap.
--
-- That was not only a probe problem: BOTH shipped Lua adapters flushed per log line, and Crystal's
-- drawn tier writes a summary every second whenever peers are present. So a real player with peers
-- on screen lost four to five frames a second, invisibly, because the number everyone watched was
-- the one that could not show it.
--
-- Hence: this lives in `dev-scripts/`, not in one game's probe folder, and it is meant to be
-- attached during any performance question about any game rather than written fresh when somebody
-- complains.
--
-- TWO INSTRUMENTS, DELIBERATELY, because they answer different questions and one of them lies in a
-- way this project has already been caught by:
--
--   * `os.clock()` measures the LUA PROCESS'S OWN CPU TIME, not wall clock. Emerald's
--     `probes/fps_probe.lua` records the trap: it read 0.44ms/frame while the user still reported
--     lag, because time spent in the emulator core does not appear in it. What it IS good for is
--     exactly this job -- a stall caused by OUR code blocking the game thread shows up in it, which
--     is what makes it a good attributor of blame.
--   * `client.get_approx_framerate()` is the emulator's own view, and is the instrument for the
--     claim "the script makes it laggy" as a whole.
--
-- Reading them together is the point: a large gap in `os.clock` means the cost is in a Lua script;
-- a low framerate with small gaps means the cost is somewhere else entirely and no amount of
-- adapter tuning will find it.
--
-- HOW TO RUN
--   Add it to whichever `bizhawk-dev-loader-*.target` is in use, ABOVE whatever is being measured,
--   and leave it there across configurations so every reading comes from the same instrument. It
--   writes `bizhawk-hitch-meter.log` beside itself.
--
--   To compare configurations, change only ONE thing between runs and keep this loaded. The table
--   that settles an argument looks like: configuration, hitches per second, worst gap.

local REPORT_EVERY_SECONDS = 1
local CONSOLE_EVERY_N_LINES = 10 -- the console is expensive; the file is not
local FLUSH_EVERY_N_REPORTS = 10 -- one hitch every ten seconds instead of one every second

local logfile
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(dir .. "/bizhawk-hitch-meter.log", "w")
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end

local rawConsole = console.log
local lines = 0
local function log(msg)
	lines = lines + 1
	if lines <= 4 or lines % CONSOLE_EVERY_N_LINES == 0 then
		rawConsole(msg)
	end
	if logfile then
		logfile:write(msg, "\n")
	end
end

log("=== BizHawk hitch meter ===")
log("A hitch is one frame that took far longer than 16.7ms. An average frame rate cannot see one,")
log("which is why this counts gaps instead. 0 hitches and a ~17ms worst gap is a healthy session.")

local frames, sinceReport, reports = 0, os.clock(), 0
local lastFrame = os.clock()
local slow1, slow2, worstGap, worstSecond = 0, 0, 0, nil

local function tick()
	frames = frames + 1

	local t = os.clock()
	local gap = t - lastFrame
	lastFrame = t
	if gap > 0.033 then
		slow2 = slow2 + 1 -- lost more than two frames' worth
	elseif gap > 0.020 then
		slow1 = slow1 + 1 -- lost more than one
	end
	if gap > worstGap then
		worstGap = gap
	end

	local elapsed = t - sinceReport
	if elapsed < REPORT_EVERY_SECONDS then
		return
	end

	local fps = frames / elapsed
	if not worstSecond or fps < worstSecond then
		worstSecond = fps
	end
	frames, sinceReport = 0, t
	reports = reports + 1

	local emuFps = nil
	pcall(function() emuFps = client.get_approx_framerate() end)

	-- Report every second while anything is wrong, once every ten when nothing is: a healthy
	-- session should not fill a log, and a struggling one is exactly when per-second detail is
	-- wanted.
	if slow1 > 0 or slow2 > 0 or fps < 55 or reports % 10 == 0 then
		log(string.format("  lua %.1f fps%s  |  hitches: %d over 20ms, %d over 33ms  |  "
			.. "worst gap %.1fms  (worst second: %.1f)",
			fps, emuFps and string.format(", emu %.1f", emuFps) or "",
			slow1, slow2, worstGap * 1000, worstSecond))
	end
	slow1, slow2, worstGap = 0, 0, 0

	if logfile and reports % FLUSH_EVERY_N_REPORTS == 0 then
		pcall(function() logfile:flush() end)
	end
end

MESHGHOST_DEV_TICK = tick

MESHGHOST_DEV_UNLOAD = function()
	if worstSecond then
		log(string.format("  --- stopping. Worst second in this configuration: %.1f fps ---",
			worstSecond))
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
