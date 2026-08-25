-- MeshGhost -- decode specific BG tiles and print them (PROBE, never shipped).
--
-- WHY. The drawn reflection's coverage mask is decoded from metatile entries plus VRAM tile
-- pixels, and it reported a covering strip HALF the width the screen shows. Either the tile really
-- is half transparent and the rest of the art sits in the layer that does not cover, or the decode
-- is wrong. Those predict the same mask and mean opposite things, so the tiles are printed raw.
--
-- Prints, for the metatile under a given grid coordinate: its attributes, its eight tilemap
-- entries, and an 8x8 opacity map of every tile they name -- read straight from VRAM at the BG
-- char base, which probes/bgread_probe.lua confirmed is readable.
-- Resolve this script's own directory instead of hardcoding one developer's
-- checkout. A tracked absolute path is unusable on anyone else's machine and is
-- the class of leak .githooks/pre-commit now refuses (pitfalls.md).
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local GBACKUPMAPLAYOUT = 0x03005dc0
local GMAPHEADER = 0x02037318
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function r32(a) return memory.read_u32_le(a) end

local out = {}
local function say(s) out[#out + 1] = s console.log("tiledecode: " .. s) end

local function metatileAt(x, y)
    local w = memory.read_s32_le(GBACKUPMAPLAYOUT)
    local m = r32(GBACKUPMAPLAYOUT + 0x08)
    if m == 0 or w <= 0 then return nil end
    return r16(m + (x + w * y) * 2) & 0x03ff
end

local function dumpMetatile(id)
    local layout = r32(GMAPHEADER)
    local ts, ix
    if id < 512 then ts, ix = r32(layout + 0x10), id else ts, ix = r32(layout + 0x14), id - 512 end
    local mts, attrs = r32(ts + 0x0c), r32(ts + 0x10)
    local a = r16(attrs + ix * 2)
    say(string.format("metatile %d  attr=%04X  behaviour=%d  layerType=%d  secondary=%s",
        id, a, a & 0xff, (a >> 12) & 0x0f, tostring(id >= 512)))
    for lay = 0, 1 do
        for quad = 0, 3 do
            local e = r16(mts + (ix * 8 + lay * 4 + quad) * 2)
            local ti = e & 0x03ff
            say(string.format("  %s quad %d: entry=%04X tile=%d pal=%d hflip=%s vflip=%s",
                lay == 0 and "BOTTOM" or "TOP   ", quad, e, ti, (e >> 12) & 0x0f,
                tostring((e & 0x0400) ~= 0), tostring((e & 0x0800) ~= 0)))
            for py = 0, 7 do
                local row = {}
                for px = 0, 7 do
                    local b = r8(0x06000000 + ti * 32 + py * 4 + (px // 2))
                    local v = (px % 2 == 0) and (b & 0x0f) or ((b >> 4) & 0x0f)
                    row[#row + 1] = (v ~= 0) and "#" or "."
                end
                say("      " .. table.concat(row))
            end
        end
    end
end

local done = false
local n = 0
local function tick()
    n = n + 1
    if done or n < 20 then return end
    done = true
    local objId = r8(GPLAYERAVATAR_ADDR + 0x05)
    local px = memory.read_s16_le(GOBJECTEVENTS_ADDR + objId * 0x24 + 0x10)
    local py = memory.read_s16_le(GOBJECTEVENTS_ADDR + objId * 0x24 + 0x12)
    say(string.format("player grid (%d,%d)", px, py))
    -- A strip either side of the player, so the ledge tiles are in it whichever way the shore runs.
    for dy = -1, 3 do
        local ids = {}
        for dx = -5, 3 do
            local id = metatileAt(px + dx, py + dy)
            local layout = r32(GMAPHEADER)
            local ts, ix
            if id and id < 512 then ts, ix = r32(layout + 0x10), id
            elseif id then ts, ix = r32(layout + 0x14), id - 512 end
            local a = id and r16(r32(ts + 0x10) + ix * 2)
            ids[#ids + 1] = id and string.format("%3d/b%-2d/L%d", id, a & 0xff, (a >> 12) & 0x0f)
                or "   --    "
        end
        say(string.format("row %+d (gy=%d): %s", dy, py + dy, table.concat(ids, " ")))
    end
    -- The metatiles the shore is actually made of, decoded pixel by pixel.
    for _, id in ipairs({ 161, 184, 2, 1 }) do dumpMetatile(id) end
    -- And the frame they were read from, so the two can be laid over each other.
    client.screenshot(MESHGHOST_DIR .. "/tiledecode.png")
    local f = io.open(MESHGHOST_DIR .. "/tiledecode.log", "w")
    if f then f:write(table.concat(out, string.char(10))) f:close() end
    console.log("tiledecode: wrote tiledecode.log")
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
