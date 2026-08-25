-- MeshGhost — DEV: walk the player a few tiles, then screenshot.
-- The surf blob is only repositioned by the engine when its rider MOVES
-- (SynchronizeSurfPosition), so a stationary frame cannot show whether an initial placement
-- error corrects itself. This drives real input to find out.
-- Resolve this script's own directory instead of hardcoding one developer's
-- checkout. A tracked absolute path is unusable on anyone else's machine and is
-- the class of leak .githooks/pre-commit now refuses (pitfalls.md).
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local HOLD, DIR = 40, "Left"
local frames, phase = 0, "walk"
MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    if phase == "walk" then
        if frames < 240 then return end -- let the adapter connect and spawn first
        pcall(function() joypad.set({ [DIR] = true }) end)
        if frames > 240 + HOLD then phase = "settle" end
        return
    end
    if phase == "settle" and frames > 240 + HOLD + 60 then
        pcall(function() client.screenshot(MESHGHOST_DIR .. "/shots/emerald/shot.png") end)
        console.log("MeshGhost: walked and shot")
        phase = "done"
    end
end
