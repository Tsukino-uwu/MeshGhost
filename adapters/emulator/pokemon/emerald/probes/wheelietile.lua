-- MeshGhost -- one tile in a wheelie, down then up, with a settle between (dev tool, holds the pad, never shipped).
-- Start it on the Acro Bike; outside the overworld, or while a script has the player, it lets go of the pad.
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GPLAYERAVATAR_ADDR = 0x02037590
local n = 0
local function tick()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or memory.read_u8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then joypad.set({}) return end
    n = (n + 1) % 260
    -- B first and the direction within a few frames is the wheelie ride; B held alone for a second hops instead.
    if n < 8 then joypad.set({ B = true })
    elseif n < 40 then joypad.set({ B = true, Down = true })
    elseif n < 130 then joypad.set({})
    elseif n < 138 then joypad.set({ B = true })
    elseif n < 170 then joypad.set({ B = true, Up = true })
    else joypad.set({}) end
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else while true do tick() emu.frameadvance() end end
