-- MeshGhost — BizHawk screenshot on a timer (DEVELOPMENT TOOL, never shipped)
--
-- The single-shot bizhawk-screenshot.lua answers "what is on screen ten seconds from now"; this
-- answers "what has been happening", which is the question a driven session actually has. It
-- writes a numbered PNG every INTERVAL_FRAMES into the game's own shots folder, so a run leaves a
-- strip of pictures rather than one frame that may or may not have caught the moment. One frame
-- cannot see a blinking thing (agent_docs/probes.md); a series can.
--
-- Per-game output, because two emulators run at once and one shared folder means two agents
-- overwriting each other's evidence: set MESHGHOST_SHOT_DIR (a global set by another loaded
-- script, or the environment) to pick the folder. Default is the vanilla Emerald one.
--
-- Costs one client.screenshot every INTERVAL_FRAMES and nothing in between.
local DIR = MESHGHOST_SHOT_DIR or os.getenv("MESHGHOST_SHOT_DIR")
    or "C:/dev/MeshGhost/dev-scripts/shots/emerald"
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
