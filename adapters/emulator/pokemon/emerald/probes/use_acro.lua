-- Gets on the Acro Bike by the game's own path (dev tool, never shipped): registers it to SELECT (SaveBlock1
-- +0x496) and presses SELECT, so the item's field effect sets every avatar flag. Writing PLAYER_AVATAR_FLAG_ACRO_BIKE
-- by hand would set the appearance and leave the bike code's own state behind. The bike must be in the bag.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local ITEM_ACRO_BIKE = 272

local n, phase = 0, "register"
local function say(s) console.log("use_acro: " .. s) end

local function tick()
    n = n + 1
    if n < 20 then return end
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1 then return end

    if phase == "register" then
        local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
        if sb1 == 0 then return end
        memory.write_u16_le(sb1 + 0x496, ITEM_ACRO_BIKE)
        say("registered the Acro Bike to SELECT")
        phase, n = "press", 0
        return
    end

    if phase == "press" then
        -- Tapped, not held: the game reads a new press.
        joypad.set({ Select = n <= 6 })
        if n > 30 then
            joypad.set({})
            phase = "done"
            say("pressed SELECT -- you should be on the Acro Bike (press SELECT again to get off)")
        end
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else
    while true do tick() emu.frameadvance() end
end
