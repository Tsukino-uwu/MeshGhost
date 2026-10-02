-- MeshGhost — Pokémon Emerald: load savestate slot 9, the checkpoint (dev tool, loads a savestate, never shipped).
-- Slot 9 holds a safe town spot; loading it undoes a scripted ride that drifted or got blocked.
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
