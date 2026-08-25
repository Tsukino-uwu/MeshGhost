-- MeshGhost -- get OFF whatever you are riding (DEV TOOL, never shipped)
--
-- WHY A WHOLE PROBE FOR ONE BUTTON. `use_acro` presses SELECT once and assumes it worked, and three
-- times in one session it silently did not -- the run carried on, the log looked plausible, and the
-- reading was of a state nobody was ever in. The user, watching: *"you never got off the bike"*.
--
-- So this one does not assume: it presses, waits long enough for the mount or dismount animation to
-- finish, LOOKS at the player's graphicsId, and presses again if it is still on a bike -- the shape
-- `use_mach.lua` already uses, and the one that has actually worked. On foot is Brendan 0 / May 89
-- (verified.md's graphicsId table).
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
