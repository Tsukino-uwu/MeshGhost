-- MeshGhost -- return to the user's checkpoint (DEV TOOL, never shipped).
-- Slot 9 is the USER's savestate, in a safe town spot. Loading it is how a scripted ride that
-- drifted or got blocked is undone; a savestate is not an in-game save, so this costs nothing.
local done, n = false, 0
local function tick()
    n = n + 1
    if done or n < 10 then return end
    done = true
    joypad.set({})
    savestate.loadslot(9)
    console.log("loadslot9: restored the user's slot 9 checkpoint")
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
