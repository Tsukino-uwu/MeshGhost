-- One screenshot after DELAY_FRAMES: on its first tick the adapter has not spawned a ghost yet, and a picture of a game
-- with no ghost in it reads as an invisible ghost.
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local DELAY_FRAMES = 600 -- 10s: connect + bridge_ready + first render_remote + spawn, comfortably
local OUT = MESHGHOST_DIR .. "/shots/emerald/shot.png"

local frames, done = 0, false
MESHGHOST_DEV_TICK = function()
    if done then return end
    frames = frames + 1
    if frames < DELAY_FRAMES then return end
    done = true
    local ok, err = pcall(function() client.screenshot(OUT) end)
    console.log(string.format("MeshGhost: screenshot after %d frames -> %s%s",
        frames, tostring(ok), (not ok) and (" (" .. tostring(err) .. ")") or ""))
end
