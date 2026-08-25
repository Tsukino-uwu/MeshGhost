-- MeshGhost -- what is walkable around the player (DEV TOOL, never shipped)
--
-- WHY. Every scripted ride today has eventually driven the player into scenery -- a fence gap, a
-- building, a ledge -- because the scripts count tiles and cannot see. The user, 2026-08-20: *"can
-- you detect npc/buildings/objects somehow? to know how to make pathing/scripts without running
-- into things?"* This answers the first half of that question by MEASUREMENT rather than by
-- asserting a bit layout from memory.
--
-- WHAT IS BEING TESTED. The map grid stores one 16-bit word per tile. `holdup.lua` already uses the
-- low ten bits of it as the metatile id, successfully, so the word and its address are known good.
-- The claim under test is that the two bits ABOVE the id (0x0C00) are the collision flags, and the
-- four above those the elevation. If that holds, a tile the player cannot enter reads non-zero
-- there and a tile they can walk onto reads zero -- and pathing becomes a lookup instead of a
-- guess.
--
-- HOW TO READ THE OUTPUT. A grid centred on the player: `.` free, `#` collision bits set, `P` the
-- player, digits an object event standing there. Compare it against the screen -- if the walls in
-- the picture are the `#`s in the grid, the layout is confirmed and every probe after this one can
-- path around them.
local GBACKUPMAPLAYOUT = 0x03005dc0
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local MAP_OFFSET = 7                      -- the grid's border, as the adapter uses it
local R = 6                               -- radius of the dump

local BSLASH = string.char(92)
local logPath = ("%s/collisionmap.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."))
local logFile = io.open(logPath, "w")
local function say(s)
    console.log("collisionmap: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

local done, n = false, 0
local function tick()
    n = n + 1
    if done or n < 30 then return end
    local w = memory.read_s32_le(GBACKUPMAPLAYOUT)
    local map = memory.read_u32_le(GBACKUPMAPLAYOUT + 0x08)
    if map == 0 or w <= 0 then return end
    done = true

    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    local po = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
    local px = memory.read_s16_le(po + 0x10) - MAP_OFFSET
    local py = memory.read_s16_le(po + 0x12) - MAP_OFFSET

    -- Where every live object event is standing, so NPCs show up as obstacles too -- they are not
    -- in the map grid at all, which is the other half of the question.
    local occupied = {}
    for i = 0, 15 do
        local a = GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE
        if (memory.read_u8(a) & 0x01) == 1 then
            occupied[string.format("%d,%d", memory.read_s16_le(a + 0x10) - MAP_OFFSET,
                memory.read_s16_le(a + 0x12) - MAP_OFFSET)] = i
        end
    end

    say(string.format("player at %d,%d -- grid width %d", px, py, w))
    for dy = -R, R do
        local row, detail = "", ""
        for dx = -R, R do
            local x, y = px + dx, py + dy
            local word = memory.read_u16_le(map + ((x + MAP_OFFSET) + w * (y + MAP_OFFSET)) * 2)
            local coll = (word >> 10) & 0x03
            local key = string.format("%d,%d", x, y)
            local ch
            if dx == 0 and dy == 0 then ch = "P"
            elseif occupied[key] then ch = tostring(occupied[key] % 10)
            elseif coll ~= 0 then ch = "#"
            else ch = "." end
            row = row .. ch
            detail = detail .. string.format("%04X ", word)
        end
        say(row .. "   | " .. detail)
    end
    say("legend: P player, # collision bits (word & 0x0C00) set, digit = object event id, . free")
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
