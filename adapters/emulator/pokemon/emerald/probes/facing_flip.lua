-- Turns on the spot forever, left, right, up, down, with a pause between (dev tool, d-pad only): a brief tap turns
-- without stepping, so a facing transition repeats on a schedule without leaving the tile. It drives input, so
-- drop it from the loader before judging anything by eye. TAP_FRAMES stays under the step threshold (a step would
-- change the sort band under test); PAUSE lets the turn finish and the sprite settle into its idle frame.
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
        -- Announced so a screenshot burst can be lined up against the turn.
        pcall(function() console.log("facing_flip: tapped " .. DIRS[i] .. " at frame " .. tostring(n)) end)
        i = (i % #DIRS) + 1
    end
end
