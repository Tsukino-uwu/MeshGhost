-- MeshGhost -- tap A a few times to clear dialogue (DEV TOOL, never shipped).
--
-- Advancing a text box is the sort of thing an agent should do for itself rather than hand back to
-- the user (agent_docs/playing.md, "Drive the game YOURSELF before asking"). Tapped, not held: the
-- game reads a NEW press, so a held A advances one box and then sits there -- and a held A on the
-- overworld would talk to whatever is in front of the player.
local n = 0
local TAPS = 14
local function tick()
    n = n + 1
    if n > TAPS * 20 then joypad.set({}) return end
    -- 10 frames down, 10 up: comfortably longer than the game's input debounce either way.
    joypad.set({ A = (n % 20) < 10 })
    if n % 20 == 0 then console.log("press_a: tap " .. (n // 20) .. "/" .. TAPS) end
end
if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else
    while true do tick() emu.frameadvance() end
end
