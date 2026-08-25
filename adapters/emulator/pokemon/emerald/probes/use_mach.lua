-- MeshGhost -- get on the MACH BIKE (DEV TOOL, never shipped)
--
-- The Acro Bike's twin of `use_acro.lua`, and the same reasoning: register the bike as the SELECT
-- item and press SELECT, so the item's real field effect sets every flag the avatar needs rather
-- than writing PLAYER_AVATAR_FLAG_MACH_BIKE by hand.
--   gSaveBlock1Ptr->registeredItem  +0x496  (include/global.h:1004)
--   ITEM_MACH_BIKE 259              (include/constants/items.h, per grant_test_kit.lua's header)
--
-- PRESSES UNTIL IT IS ACTUALLY ON, up to a few times, because one press does different things
-- depending on where you start: on foot it mounts, on the OTHER bike it has to get off first. The
-- graphicsId says which state we are in -- Brendan 1 / May 90 is the Mach Bike (verified.md's
-- table) -- so the probe can simply look rather than assume a fixed number of presses.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local ITEM_MACH_BIKE = 259

local n, tries, done = 0, 0, false
local function say(s) console.log("use_mach: " .. s) end

local function tick()
    if done then return end
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or memory.read_u8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then joypad.set({}) return end

    n = n + 1
    if n < 20 then return end
    local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return end
    memory.write_u16_le(sb1 + 0x496, ITEM_MACH_BIKE)

    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return end
    local gfx = memory.read_u8(GOBJECTEVENTS_ADDR + objId * 0x24 + 0x05)
    if gfx == 1 or gfx == 90 then
        joypad.set({})
        done = true
        say("on the Mach Bike (graphicsId " .. gfx .. ")")
        return
    end

    -- Tapped, not held: the game reads a NEW press. One press per 90 frames, so the mount or
    -- dismount it starts has finished before the next is judged.
    local t = (n - 20) % 90
    joypad.set({ Select = t < 6 })
    if t == 0 then
        tries = tries + 1
        if tries > 4 then done = true joypad.set({}) say("gave up -- still graphicsId " .. gfx) end
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else while true do tick() emu.frameadvance() end end
