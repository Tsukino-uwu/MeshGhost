-- Turn on the spot, forever: left, right, up, down, with a pause between each. DEV TOOL, d-pad only.
--
-- Emerald turns without stepping when a direction is tapped briefly -- the engine's own
-- "turn in place" -- so this reproduces a facing TRANSITION over and over without the player ever
-- leaving the tile. Written for the draw-order mask, where the user reported the fault only during
-- the transition itself: *"standing idle looks fine but the small transition from facing left to
-- right has some green in it"*. A fault that lives in three frames needs to be made to happen on a
-- schedule before any instrument can catch it.
--
-- WHAT IT IS NOT: a passive instrument. It drives input, so drop it from the loader's target file
-- before judging anything by eye.
--
-- THE TAP IS SHORT ON PURPOSE. Holding a direction past the turn frames starts a STEP, which moves
-- the player off the tile and changes the very sort band the test is about -- the probe would then
-- be measuring its own movement. TAP_FRAMES is under Emerald's step threshold; PAUSE is long enough
-- for the turn to finish and the sprite to settle into its idle frame.
local TAP_FRAMES = 2
local PAUSE = 40

local DIRS = { "Left", "Right", "Up", "Down" }
local n, i = 0, 1

MESHGHOST_DEV_TICK = function()
    n = n + 1
    local phase = n % (TAP_FRAMES + PAUSE)
    if phase < TAP_FRAMES then
        pcall(joypad.set, { [DIRS[i]] = true })
        pcall(joypad.set, { [DIRS[i]] = true }, 1)
    elseif phase == TAP_FRAMES then
        -- Announce the turn that just happened, so a screenshot burst can be lined up against it.
        pcall(function() console.log("facing_flip: tapped " .. DIRS[i] .. " at frame " .. tostring(n)) end)
        i = (i % #DIRS) + 1
    end
end
