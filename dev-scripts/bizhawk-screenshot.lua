-- MeshGhost — BizHawk screenshot after a delay (DEVELOPMENT TOOL, never shipped)
--
-- WAITS before shooting, and that is the whole point. The first version fired on its first tick,
-- which is a frame or two after the loader starts it -- long before the adapter has connected,
-- been accepted, received a peer and spawned a ghost. It produced three "the ghost is invisible"
-- screenshots in a row of a game that simply had no ghost in it yet, and sent a debugging session
-- chasing a rendering bug that did not exist.
--
-- A probe that measures the wrong moment does not fail; it answers a different question
-- convincingly. See agent_docs/probes.md and pitfalls.md.
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
