-- Gets off whatever the player is riding, and confirms it (dev tool, never shipped): presses SELECT, waits out the
-- dismount animation, reads graphicsId, and presses again while still on a bike. On foot is Brendan 0 / May 89.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

local n, tries, done = 0, 0, false
local function say(s) console.log("dismount: " .. s) end

local function tick()
    if done then return end
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or memory.read_u8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then joypad.set({}) return end

    n = n + 1
    if n < 20 then return end
    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return end
    local gfx = memory.read_u8(GOBJECTEVENTS_ADDR + objId * 0x24 + 0x05)
    if gfx == 0 or gfx == 89 then
        joypad.set({})
        done = true
        say("on foot (graphicsId " .. gfx .. ")")
        return
    end

    local t = (n - 20) % 90
    joypad.set({ Select = t < 8 })
    if t == 0 then
        tries = tries + 1
        if tries > 4 then done = true joypad.set({}) say("gave up -- still graphicsId " .. gfx) end
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else while true do tick() emu.frameadvance() end end
