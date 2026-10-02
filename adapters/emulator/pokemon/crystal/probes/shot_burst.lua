-- Pokémon Crystal: a screenshot a second, to tell an engine-drawn character from a painted one. Writes only PNGs.
-- client.screenshot captures the emulated framebuffer without the Lua overlay, so an engine character appears in the
-- shot and a drawn-tier one does not. Files cycle through shots/burst_NN.png beside this script.

local EVERY = 60 -- frames between shots: one a second, the cadence orphan_probe reports at
local KEEP = 24 -- ~24 seconds of history before it wraps

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

local DIR = scriptDir() .. "/shots"
local frames, n = 0, 0

console.log("MeshGhost: screenshot burst -- one a second into " .. DIR
	.. "/burst_NN.png. A character in these images is drawn by the ENGINE; "
	.. "the drawn tier does not appear in a screenshot at all.")

local function tick()
	frames = frames + 1
	if frames % EVERY ~= 0 then
		return
	end
	n = (n % KEEP) + 1
	-- pcall: a failed capture must not throw, since the dev loader unloads a target that does.
	pcall(client.screenshot, string.format("%s/burst_%02d.png", DIR, n))
end

if MESHGHOST_DEV_LOADER then
	MESHGHOST_DEV_TICK = tick
else
	while true do
		tick()
		emu.frameadvance()
	end
end
