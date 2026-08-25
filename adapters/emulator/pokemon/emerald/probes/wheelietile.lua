-- MeshGhost -- one tile, in a wheelie (DEV TOOL, never shipped)
--
-- WHY. The user, 2026-08-20: in a wheelie, one tile down, the SPAWNED ghost plays *"the while
-- cosntantly riding animation instead of just the small wiggle"*. A wheelie ride has to be entered
-- before it can be steered -- B held first, then a direction -- so a plain tap never produces it.
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
    -- Hold B alone long enough to be up on the back wheel, then ONE tile, then let everything
    -- settle before the next one -- the whole point is to see a single tile in isolation.
    -- B FIRST, THEN THE DIRECTION WITHIN A FEW FRAMES -- that is the wheelie RIDE. Holding B for a
    -- second gives the bunny hop instead, which is what the first version of this measured by
    -- mistake (the log came back full of 0x70/0x71 hop actions and no ride at all).
    if n < 8 then joypad.set({ B = true })
    elseif n < 40 then joypad.set({ B = true, Down = true })
    elseif n < 130 then joypad.set({})
    elseif n < 138 then joypad.set({ B = true })
    elseif n < 170 then joypad.set({ B = true, Up = true })
    else joypad.set({}) end
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else while true do tick() emu.frameadvance() end end
