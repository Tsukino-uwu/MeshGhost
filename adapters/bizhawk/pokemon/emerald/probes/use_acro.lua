-- MeshGhost -- get on the ACRO BIKE (DEV TOOL, never shipped)
--
-- WHY. The Acro Bike has states the Mach Bike does not -- a standing wheelie, a moving wheelie and
-- the bunny hop (sAcroBikeTransitions, pokeemerald src/bike.c) -- and reaching them means being on
-- it. Switching bikes is normally a trip to Rydel's or a dive through the bag; both are the user's
-- time spent on what a script does (agent_docs/playing.md).
--
-- HOW, using the game's own path rather than poking the avatar's state: register the ACRO BIKE as
-- the SELECT item and press SELECT. That runs the item's real field effect, so every flag the
-- avatar needs is set by the game itself -- writing PLAYER_AVATAR_FLAG_ACRO_BIKE by hand would set
-- the appearance and leave the bike code's own state behind it.
--   gSaveBlock1Ptr->registeredItem  +0x496  (include/global.h:1004)
--   ITEM_ACRO_BIKE 272              (include/constants/items.h, per grant_test_kit.lua's header)
-- The kit already put both bikes in the bag, so the item is there to register.
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
        -- Tapped, not held: the game reads a NEW press.
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
