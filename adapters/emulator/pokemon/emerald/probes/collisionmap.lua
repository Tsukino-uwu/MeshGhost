-- What is walkable around the player: a grid of the map words round it, `.` free, `#` collision bits (0x0C00) set,
-- `P` the player, a digit an object event, to compare against the screen. Reads only.
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

    -- Characters are not in the map grid at all, so every live object event is marked too.
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
