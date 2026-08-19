-- What hides a character standing in tall grass? (PROBE, never shipped)
-- The player is visibly occluded by grass, so whatever does it is readable from the tile they are
-- on: if it is the metatile's TOP layer, the drawn tier's existing BG mask should already handle
-- it; if the top layer is empty, the occlusion is a field-effect SPRITE and needs different work.
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GBACKUPMAPLAYOUT = 0x03005dc0
local GMAPHEADER = 0x02037318
local done, n = false, 0
local function tick()
    n = n + 1
    if done or n < 20 then return end
    done = true
    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    local o = GOBJECTEVENTS_ADDR + objId * 0x24
    local x = memory.read_s16_le(o + 0x10)
    local y = memory.read_s16_le(o + 0x12)
    local w = memory.read_s32_le(GBACKUPMAPLAYOUT)
    local map = memory.read_u32_le(GBACKUPMAPLAYOUT + 0x08)
    local layout = memory.read_u32_le(GMAPHEADER)
    for dy = -1, 1 do
        local id = memory.read_u16_le(map + (x + w * (y + dy)) * 2) & 0x03ff
        local ts, ix
        if id < 512 then ts, ix = memory.read_u32_le(layout + 0x10), id
        else ts, ix = memory.read_u32_le(layout + 0x14), id - 512 end
        local attrs = memory.read_u32_le(ts + 0x10)
        local a = memory.read_u16_le(attrs + ix * 2)
        local mts = memory.read_u32_le(ts + 0x0c)
        local top = {}
        for q = 0, 3 do top[#top+1] = string.format("%04X", memory.read_u16_le(mts + (ix*8+4+q)*2)) end
        local bot = {}
        for q = 0, 3 do bot[#bot+1] = string.format("%04X", memory.read_u16_le(mts + (ix*8+q)*2)) end
        console.log(string.format("grassdump: (%d,%d) id=%d behaviour=%d layerType=%d",
            x, y+dy, id, a & 0xff, (a >> 12) & 0x0f))
        console.log("grassdump:    BOTTOM " .. table.concat(bot, " ")
            .. "   TOP " .. table.concat(top, " "))
    end
    -- And the field-effect sprites the engine has live right now, which is the other candidate.
    local n2 = 0
    for i = 0, 63 do
        local d = 0x02020630 + i * 0x44
        if (memory.read_u8(d + 0x3e) & 0x01) ~= 0 and memory.read_u32_le(d + 0x1c) ~= 0 then
            n2 = n2 + 1
        end
    end
    console.log("grassdump: " .. n2 .. " sprites in use")
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
