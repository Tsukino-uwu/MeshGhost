-- MeshGhost — Pokémon Emerald: the emulator's top speed, frame limiter off, for pricing whatever else is
-- loaded (DEV TOOL, READ-ONLY on the game, turns the frame limiter off for its sample and back on;
-- never shipped) -- 2026-09-16
--
-- WHY THIS EXISTS. autoplay's Emerald module installs execute hooks to read text, and an execute hook
-- costs top speed (`emerald/MEASURED.md`, the text entry: 344 frames/s with none, 242.0 with five, one
-- instance). A sixth was added; this prices the set as loaded, against a run with none, in one place.
--
-- HOW. Checks that `emu.limitframerate` exists in this build before calling it (no API listing of this
-- build is kept), waits WARMUP frames after loading, turns the limiter off, samples
-- `client.get_approx_framerate()` every EVERY frames for SAMPLES samples, turns the limiter back on, logs
-- the samples and their median, and stops. Presses nothing; stand still while it runs.
-- WHAT IT CANNOT SEE: which loaded script costs what (load one set per run); anything the limiter's
-- setting does not govern.

local WARMUP, EVERY, SAMPLES, SETTLE = 120, 120, 30, 10

local dir = "."
do
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
	end
end
local logf = io.open(string.format("%s/hookcost_probe_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
local function log(s)
	if logf then
		logf:write(string.format("f%d %s\n", emu.framecount(), s))
		logf:flush() -- a dozen lines in all
	end
end

-- BizHawk's own functions are userdata here, not Lua functions (get_approx_framerate read so).
local canLimit = type(emu) == "table" and emu.limitframerate ~= nil
log("emu.limitframerate is " .. (canLimit and type(emu.limitframerate) or "absent") .. "; get_approx_framerate is " ..
	type(client.get_approx_framerate))

local frames, samples, done = 0, {}, not canLimit
MESHGHOST_DEV_TICK = function()
	if done then return end
	frames = frames + 1
	if frames == WARMUP then
		emu.limitframerate(false)
		log("limiter off")
	elseif frames > WARMUP and (frames - WARMUP) % EVERY == 0 then
		samples[#samples + 1] = client.get_approx_framerate()
		if #samples >= SAMPLES then
			emu.limitframerate(true)
			-- The reading is smoothed and climbs for a while after the limiter goes off (60 to 778 over
			-- the first 10 samples of a no-hook run), so the median is of the samples after SETTLE.
			local sorted = { table.unpack(samples, SETTLE + 1) }
			table.sort(sorted)
			local strs = {}
			for i, v in ipairs(samples) do strs[i] = string.format("%.1f", v) end
			log("limiter on; samples " .. table.concat(strs, " ") .. string.format("; median %.1f",
				(sorted[#sorted // 2] + sorted[#sorted // 2 + 1]) / 2))
			done = true
		end
	end
end
MESHGHOST_DEV_UNLOAD = function()
	if canLimit and not done then
		emu.limitframerate(true)
		log("unloaded mid-sample; limiter on")
	end
	if logf then logf:close() end
	logf = nil
end
