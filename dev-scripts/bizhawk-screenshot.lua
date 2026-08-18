-- MeshGhost — BizHawk screenshot (DEVELOPMENT TOOL, never shipped)
--
-- WHY THIS COULD MATTER MORE THAN ANYTHING ELSE HERE
-- Every rule in this project about live testing rests on one premise: the agent cannot see the
-- screen, so a claim about what the game DOES needs a human to watch it. That premise is what
-- makes each test cost the user's attention. If BizHawk can write a PNG, the agent can read that
-- PNG -- and a whole class of "is it actually drawing correctly?" questions becomes checkable
-- without asking anyone.
--
-- It does NOT make the human redundant, and the difference is worth stating: a screenshot answers
-- "what is on screen right now", which is not the same as "does this look right while moving".
-- Every one of the six bugs found on 2026-08-18 was a MOTION or INTERACTION defect -- a ghost
-- mirroring the player's animation, a frozen ghost, a walk that should have been a run. A still
-- frame would have caught almost none of them. Treat this as a new instrument, not a replacement
-- for watching.
local OUT = "C:/dev/MeshGhost/dev-scripts/shot.png"

local done = false
MESHGHOST_DEV_TICK = function()
    if done then return end
    done = true
    local ok, err = pcall(function() client.screenshot(OUT) end)
    console.log(string.format("MeshGhost: screenshot -> %s%s", tostring(ok),
        (not ok) and (" (" .. tostring(err) .. ")") or ""))
end
