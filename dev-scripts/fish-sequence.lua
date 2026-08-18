-- MeshGhost — DEV: drive the player through "use the Super Rod on water", screenshotting each
-- step so the sequence can be corrected without guessing.
--
-- WHY do it in the real game rather than force the fishing graphic on a ghost: surfing taught us
-- that a state can be a pose PLUS a companion sprite, and only performing it shows what the engine
-- actually creates. See agent_docs/effect-investigation.md.
--
-- Steps are separated by generous waits, and each writes shotN.png. Menu layouts are guessed on
-- the first run; the screenshots say where the cursor really is.
local STEPS = {
    { wait = 260, press = nil,     shot = "1-start" },   -- water placed by watertile.lua by now
    { wait = 40,  press = "Start", shot = "2-menu" },
    { wait = 40,  press = "Down",  shot = "3-down" },
    { wait = 30,  press = "Down",  shot = "4-down" },
    { wait = 30,  press = "A",     shot = "5-bag" },
    { wait = 50,  press = "Right", shot = "6-pocket" },
}
local i, frames, held = 1, 0, 0
MESHGHOST_DEV_TICK = function()
    if i > #STEPS then return end
    frames = frames + 1
    local step = STEPS[i]
    if frames < step.wait then return end
    if step.press and held < 4 then
        -- A button must be held a few frames to register, and released before the next press.
        pcall(function() joypad.set({ [step.press] = true }) end)
        held = held + 1
        return
    end
    if held < 12 then held = held + 1 return end -- let the UI settle before the shot
    pcall(function()
        client.screenshot("C:/dev/MeshGhost/dev-scripts/step-" .. step.shot .. ".png")
    end)
    console.log("MeshGhost: step " .. step.shot)
    i, frames, held = i + 1, 0, 0
end
