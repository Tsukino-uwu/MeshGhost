-- A numbered PNG every INTERVAL_FRAMES, for what has been happening: one frame cannot see a blinking thing. Into
-- MESHGHOST_SHOT_DIR (a global or the environment), one folder per game so two emulators never overwrite each other.
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local DIR = MESHGHOST_SHOT_DIR or os.getenv("MESHGHOST_SHOT_DIR")
    or MESHGHOST_DIR .. "/shots/emerald"
local PREFIX = MESHGHOST_SHOT_PREFIX or os.getenv("MESHGHOST_SHOT_PREFIX") or "loop"
local INTERVAL_FRAMES = tonumber(MESHGHOST_SHOT_INTERVAL or os.getenv("MESHGHOST_SHOT_INTERVAL") or "")
    or 120 -- 2s at 60fps

local frames, shots = 0, 0
MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    if frames % INTERVAL_FRAMES ~= 0 then return end
    shots = shots + 1
    local path = string.format("%s/%s_%03d.png", DIR, PREFIX, shots)
    local ok, err = pcall(function() client.screenshot(path) end)
    if not ok then
        console.log("MeshGhost: screenshot failed: " .. tostring(err))
    end
end
