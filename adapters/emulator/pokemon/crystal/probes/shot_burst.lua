-- MeshGhost — Pokémon Crystal: a burst of screenshots, to tell a PAINTED character from an ENGINE one
--
-- DEVELOPMENT TOOL. Writes PNGs beside this script and nothing else -- no game memory, no input.
--
-- WHY THIS IS THE RIGHT INSTRUMENT FOR ONE PARTICULAR QUESTION
-- `client.screenshot` captures the EMULATED FRAMEBUFFER, without BizHawk's Lua overlay. That is
-- normally a nuisance -- it is why no screenshot has ever shown the drawn tier (`meshghost_crystal
-- .lua`, the handover comment, 2026-08-23) -- but it makes it the perfect discriminator here:
--
--   * a character the ENGINE is drawing (an object struct) APPEARS in the shot;
--   * a character THIS ADAPTER paints (the drawn tier) is INVISIBLE in the shot.
--
-- So for an extra character nobody can account for, one image answers "which renderer put it
-- there" -- a question the object arrays cannot settle, because they only ever describe one of the
-- two renderers. Asked 2026-08-26, after the object-array probe reported one ghost in the array
-- while the user could see two on screen.
--
-- A BURST, NOT A SHOT. The thing being caught is intermittent and tied to a promotion, so a single
-- well-timed capture is a window to hit -- and probes ask for endurance, not timing. This takes
-- one every second for as long as it is loaded, numbered in order, so the sequence can be scanned
-- afterwards for the frame that has the extra character in it. Old files are overwritten by number
-- rather than accumulating forever.
--
-- HOW TO RUN
--   Add it to a dev loader target. Files land in shots/crystal/burst_NN.png beside this script's
--   own folder. Remove the line to stop it.

local EVERY = 60 -- frames between shots: one a second, which is the same cadence orphan_probe
-- reports at, so a shot can be lined up against a dump.
local KEEP = 24 -- ~24 seconds of history before it wraps. Two full idle/promote cycles.

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
	-- pcall: a failed capture (a locked file, a path that does not exist yet) must not take the
	-- adapter down with it -- the dev loader unloads a target that throws, and this one shares its
	-- session with the thing actually being measured.
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
