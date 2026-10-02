-- MeshGhost — tap A a few times to clear dialogue (dev tool, presses the pad, never shipped).
local n = 0
local TAPS = 14
local function tick()
    n = n + 1
    if n > TAPS * 20 then joypad.set({}) return end
    -- Tapped, not held: the game acts on a new press, so a held A advances one box and sits there.
    joypad.set({ A = (n % 20) < 10 })
    if n % 20 == 0 then console.log("press_a: tap " .. (n // 20) .. "/" .. TAPS) end
end
if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else
    while true do tick() emu.frameadvance() end
end
