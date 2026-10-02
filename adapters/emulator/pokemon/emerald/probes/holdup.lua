-- Holds Up and nothing else, for a Mach Bike climb from the tile in front of a muddy slope. Once a second it logs
-- the y coordinate, the speed reached and the behaviour underfoot: holding the key and climbing are separate claims.
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GBACKUPMAPLAYOUT = 0x03005dc0
local GMAPHEADER = 0x02037318
local MB_MUDDY_SLOPE = 208

local n, stopped, peak, startY, lastY = 0, false, 0, nil, nil
local function say(s) console.log("holdup: " .. s) end
local function r8(a) return memory.read_u8(a) end

local function behaviourAt(x, y)
    local w = memory.read_s32_le(GBACKUPMAPLAYOUT)
    local map = memory.read_u32_le(GBACKUPMAPLAYOUT + 0x08)
    if map == 0 or w <= 0 then return nil end
    local id = memory.read_u16_le(map + (x + w * y) * 2) & 0x03ff
    local layout = memory.read_u32_le(GMAPHEADER)
    if layout == 0 then return nil end
    local ts, ix
    if id < 512 then ts, ix = memory.read_u32_le(layout + 0x10), id
    else ts, ix = memory.read_u32_le(layout + 0x14), id - 512 end
    if ts == 0 then return nil end
    local attrs = memory.read_u32_le(ts + 0x10)
    if attrs == 0 then return nil end
    return memory.read_u16_le(attrs + ix * 2) & 0xff
end

local function tick()
    if stopped then return end
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or r8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then
        stopped = true
        joypad.set({})
        say("STOPPED (the player is not ours to move) -- keys released")
        return
    end

    local objId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return end
    local o = GOBJECTEVENTS_ADDR + objId * 0x24
    local x = memory.read_s16_le(o + 0x10)
    local y = memory.read_s16_le(o + 0x12)
    if not startY then startY, lastY = y, y say(string.format("holding Up from (%d,%d)", x, y)) end

    local speed = r8(GPLAYERAVATAR_ADDR + 0x0b)
    if speed > peak then peak = speed end

    n = n + 1
    if n % 60 == 0 then
        local b = behaviourAt(x, y)
        say(string.format("at (%d,%d) climbed %d tiles (%+d since last second) speed=%d peak=%d "
            .. "behaviour=%s%s", x, y, startY - y, lastY - y, speed, peak, tostring(b),
            b == MB_MUDDY_SLOPE and " MUD" or ""))
        lastY, peak = y, 0
    end

    joypad.set({ Up = true })
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) say("unloaded, keys released") end
else
    while true do tick() emu.frameadvance() end
end
