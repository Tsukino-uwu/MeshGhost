-- The hitch meter, game-agnostic and read-only: frames over 20ms, over 33ms, and the worst gap, because a frame rate
-- is an average and an average cannot see one long frame. Its log is buffered and the console throttled: an
-- instrument that costs frame time cannot measure it.
--
-- os.clock is the Lua process's own CPU time, so a big gap in it puts the cost in a Lua script; a low
-- client.get_approx_framerate with small gaps puts it elsewhere, where no adapter tuning will find it.
-- List it above what is being measured and keep it loaded across configurations, changing one thing per run.

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
	logfile = io.open(dir .. "/../dev-logs/bizhawk-hitch-meter.log", "w")
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
		slow2 = slow2 + 1 -- longer than two frames
	elseif gap > 0.020 then
		slow1 = slow1 + 1 -- longer than one, with a margin
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

	-- Every second while anything is wrong, every tenth while nothing is.
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

-- A registered callback outlives its script under BizHawk, hence a loop and not event.onframeend.
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
