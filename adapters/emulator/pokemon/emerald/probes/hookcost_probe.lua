-- MeshGhost — Emerald: top speed with the frame limiter off, pricing what else is loaded, one set per run (dev tool).
-- Presses nothing, turns the limiter back on after its sample, and logs the samples and their median. Stand still.

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

-- BizHawk's own functions are userdata here, not Lua functions, so a type check for "function" misses them.
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
			-- The reading is smoothed and climbs after the limiter goes off, so the median skips the first SETTLE.
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
