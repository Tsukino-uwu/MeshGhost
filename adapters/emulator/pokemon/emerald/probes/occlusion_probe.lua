-- Read-only: walks the painted tier's occlusion chain (gBackupMapLayout -> metatile id -> gMapHeader -> tileset ->
-- attributes) and prints every link raw, for a build where every run is clipped away with no error. It shows
-- plausibility, not correctness: a wrong ROM pointer looks like a right one, so diff a vanilla run against the
-- patched build's.

local SAMPLES = 1
local done = false

local SCRIPT_DIR = (function()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end)()

local function say(line)
    console.log(line)
    local f = io.open(SCRIPT_DIR .. "/occlusion_probe.log", "a")
    if f then f:write(line, "\n") f:close() end
end

local function r32(a) return memory.read_u32_le(a) end
local function r16(a) return memory.read_u16_le(a) end

local function tick()
    if done then return end
    done = true

    say("=== OCCLUSION CHAIN " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===")
    say(string.format("  ROM game code 0x080000AC : %s",
        (memory.read_u8(0x080000AC) and string.char(
            memory.read_u8(0x080000AC), memory.read_u8(0x080000AD),
            memory.read_u8(0x080000AE), memory.read_u8(0x080000AF))) or "?"))

    -- 1. the map layout triple
    local width = memory.read_s32_le(0x03005dc0)
    local height = memory.read_s32_le(0x03005dc0 + 0x04)
    local map = r32(0x03005dc0 + 0x08)
    say(string.format("  gBackupMapLayout 0x03005DC0: width=%d height=%d map=%08X", width, height, map))

    -- 2. gMapHeader and the two tilesets it points at
    local layout = r32(0x02037318)
    say(string.format("  gMapHeader 0x02037318      : layout=%08X", layout))
    if layout ~= 0 then
        local t1, t2 = r32(layout + 0x10), r32(layout + 0x14)
        say(string.format("    tileset primary=%08X secondary=%08X", t1, t2))
        for name, t in pairs({ primary = t1, secondary = t2 }) do
            if t ~= 0 then
                say(string.format("    %s: attributes=%08X metatiles=%08X",
                    name, r32(t + 0x10), r32(t + 0x0C)))
            end
        end
    end

    -- 3. what the attribute read actually yields for the tiles under the player
    local sb1 = r32(0x03005d8c)
    say(string.format("  gSaveBlock1Ptr             : %08X", sb1))
    if sb1 ~= 0 and map ~= 0 and width > 0 then
        local px, py = memory.read_s16_le(sb1), memory.read_s16_le(sb1 + 2)
        say(string.format("  player tile (saveblock)    : (%d,%d)", px, py))
        -- MAP_OFFSET is 7; a small window shows whether any of these look like plausible behaviour bytes.
        for dy = 0, 1 do
            local row = {}
            for dx = -1, 1 do
                local x, y = px + 7 + dx, py + 7 + dy
                local id, attr = -1, -1
                if x >= 0 and y >= 0 and x < width and y < height then
                    id = r16(map + (x + width * y) * 2) & 0x03ff
                    if layout ~= 0 then
                        local ts, idx
                        if id < 512 then ts, idx = r32(layout + 0x10), id
                        else ts, idx = r32(layout + 0x14), id - 512 end
                        if ts ~= 0 then
                            local attrs = r32(ts + 0x10)
                            if attrs ~= 0 then attr = r32(attrs + idx * 4) end
                        end
                    end
                end
                row[#row + 1] = string.format("id=%3d attr=%08X", id, attr)
            end
            say("    row+" .. dy .. ": " .. table.concat(row, " | "))
        end
    end
    say("  (diff this against the same probe on VANILLA -- a wrong pointer looks like a right one)")
end

MESHGHOST_DEV_UNLOAD = function() end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
