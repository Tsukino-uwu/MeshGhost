-- Where is the muddy slope on this map? (PROBE, never shipped)
-- Scans the loaded map grid for MB_MUDDY_SLOPE (208) and reports the block, so a ride can be put
-- at the bottom of it instead of hunting by eye.
local GBACKUPMAPLAYOUT = 0x03005dc0
local GMAPHEADER = 0x02037318
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local MB_MUDDY_SLOPE = 208
local done, n = false, 0
local function tick()
    n = n + 1
    if done or n < 20 then return end
    done = true
    local w = memory.read_s32_le(GBACKUPMAPLAYOUT)
    local h = memory.read_s32_le(GBACKUPMAPLAYOUT + 0x04)
    local map = memory.read_u32_le(GBACKUPMAPLAYOUT + 0x08)
    local layout = memory.read_u32_le(GMAPHEADER)
    if map == 0 or layout == 0 or w <= 0 then console.log("findmud: no map") return end
    local objId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
    local o = GOBJECTEVENTS_ADDR + objId * 0x24
    local px = memory.read_s16_le(o + 0x10)
    local py = memory.read_s16_le(o + 0x12)
    console.log(string.format("findmud: map is %dx%d, player at (%d,%d)", w, h, px, py))
    local minx, maxx, miny, maxy, count = 9999, -1, 9999, -1, 0
    local cols = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local id = memory.read_u16_le(map + (x + w * y) * 2) & 0x03ff
            local ts, ix
            if id < 512 then ts, ix = memory.read_u32_le(layout + 0x10), id
            else ts, ix = memory.read_u32_le(layout + 0x14), id - 512 end
            if ts ~= 0 then
                local attrs = memory.read_u32_le(ts + 0x10)
                if attrs ~= 0 and (memory.read_u16_le(attrs + ix * 2) & 0xff) == MB_MUDDY_SLOPE then
                    count = count + 1
                    if x < minx then minx = x end
                    if x > maxx then maxx = x end
                    if y < miny then miny = y end
                    if y > maxy then maxy = y end
                    cols[x] = (cols[x] or 0) + 1
                end
            end
        end
    end
    if count == 0 then console.log("findmud: NO muddy slope on this map") return end
    console.log(string.format("findmud: %d mud tiles, x %d..%d, y %d..%d", count, minx, maxx, miny, maxy))
    local best, bestn = nil, -1
    for x, c in pairs(cols) do if c > bestn then best, bestn = x, c end end
    console.log(string.format("findmud: tallest column is x=%d with %d mud tiles -- ride there, "
        .. "starting a few tiles BELOW y=%d", best, bestn, maxy))
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
