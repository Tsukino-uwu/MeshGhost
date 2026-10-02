-- Squares of 1, 2 and 3 tiles a side on the Mach Bike (dev tool, never shipped): the bike speeds up over distance,
-- so a long leg is always at top speed and says nothing about the speeds below it. Counted in tiles, not frames,
-- so the route stays where it started.
local GPLAYERAVATAR_ADDR = 0x02037590
local GBACKUPMAPLAYOUT = 0x03005dc0
local GOBJECTEVENTS_ADDR = 0x02037350
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local OBJECTEVENT_SIZE = 0x24

local SIDES = { 1, 1, 2, 2, 3 }          -- each square ridden twice at the short lengths
local DIRS = { "Up", "Left", "Down", "Right" }
-- The tile each direction steps into, in the same order. North is -y on this map grid.
local STEP = { {0, -1}, {-1, 0}, {0, 1}, {1, 0} }

-- A lead-in first: the probe starts wherever the last run left the player, once a fence gap it could only ride into.
local LEAD_IN_TILES = 5
local sideAt, leg, startX, startY, pause, held = 1, 1, nil, nil, 0, 0
local leadX, leadY, ledIn = nil, nil, false
local function say(s) console.log("machsquare: " .. s) end

-- Collision is bits 10-11 of the grid word; an NPC blocks a tile the grid calls free, so objects are checked too.
local function canStandAt(x, y)
    local w = memory.read_s32_le(GBACKUPMAPLAYOUT)
    local map = memory.read_u32_le(GBACKUPMAPLAYOUT + 0x08)
    if map == 0 or w <= 0 then return true end
    local word = memory.read_u16_le(map + (x + w * y) * 2)
    if ((word >> 10) & 0x03) ~= 0 then return false end
    for i = 0, 15 do
        local a = GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE
        if (memory.read_u8(a) & 0x01) == 1
            and memory.read_s16_le(a + 0x10) == x and memory.read_s16_le(a + 0x12) == y
        then return false end
    end
    return true
end

local function tick()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or memory.read_u8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then joypad.set({}) return end

    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return end
    local o = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
    local x = memory.read_s16_le(o + 0x10)
    local y = memory.read_s16_le(o + 0x12)

    -- A pause between legs: each leg starts from a standstill, which is what produces the slow frames.
    if pause > 0 then pause = pause - 1 joypad.set({}) return end

    if not ledIn then
        if not leadX then leadX, leadY = x, y say("lead-in: " .. LEAD_IN_TILES .. " tiles down") end
        held = held + 1
        if math.abs(x - leadX) + math.abs(y - leadY) >= LEAD_IN_TILES or held > 240 then
            ledIn, held, pause = true, 0, 45
            joypad.set({})
            return
        end
        joypad.set({ Down = true })
        return
    end

    if not startX then
        startX, startY = x, y
        say(string.format("square of %d, leg %d (%s)", SIDES[sideAt], leg, DIRS[leg]))
    end
    -- Look before riding: a blocked next tile ends the leg and the square turns early.
    if not canStandAt(x + STEP[leg][1], y + STEP[leg][2]) then
        say(string.format("blocked %s at %d,%d -- turning early", DIRS[leg], x, y))
        startX, startY, pause, held = nil, nil, 30, 0
        leg = leg + 1
        if leg > #DIRS then leg = 1 sideAt = sideAt % #SIDES + 1 end
        joypad.set({})
        return
    end
    -- A leg held against scenery never reaches its tile count, so time ends it as a backstop.
    held = held + 1
    if math.abs(x - startX) + math.abs(y - startY) >= SIDES[sideAt] or held > 150 then
        startX, startY, pause, held = nil, nil, 45, 0
        leg = leg + 1
        if leg > #DIRS then
            leg = 1
            sideAt = sideAt % #SIDES + 1
        end
        joypad.set({})
        return
    end
    joypad.set({ [DIRS[leg]] = true })
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) say("unloaded, keys released") end
else while true do tick() emu.frameadvance() end end
