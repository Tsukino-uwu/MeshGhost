-- MeshGhost -- does a ghost's SPRITE ever go invisible across a seam? (DEV TOOL, never shipped)
--
-- The user, after cross-map ghosts landed: both ghosts *"disappear a bit slightly during the
-- transition"*. The drawn tier's blink had a mechanical cause (the clear-without-repaint frames,
-- fixed); this asks whether the SPAWNED tier blinks at all: per frame, for every active object
-- with the ghost localId, the sprite's invisible flag and its on-/off-screen position. A line is
-- written only when something changes, so a crossing produces a handful of lines that say exactly
-- which frames, if any, the engine hid the sprite.
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE = 0x24
local SPRITE_SIZE = 0x44
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c

local BSLASH = string.char(92)
local logPath = ("%s/blinkwatch.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."))
local logFile = io.open(logPath, "w")
local function say(s) if logFile then logFile:write(s .. string.char(10)) logFile:flush() end end

local last, n = nil, 0
local function tick()
    n = n + 1
    local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return end
    local key = memory.read_u8(sb1 + 0x04) .. ":" .. memory.read_u8(sb1 + 0x05)
    local parts = {}
    for i = 0, 15 do
        local a = GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE
        if (memory.read_u8(a) % 2) == 1 and memory.read_u8(a + 0x08) == 255 then
            local d = GSPRITES_ADDR + memory.read_u8(a + 0x04) * SPRITE_SIZE
            -- sprite +0x3E: bit 0 inUse, bit 2 invisible (pokeemerald include/gba/types.h side of
            -- struct Sprite; the adapter already flips these exact bits in despawnGhost).
            local inv = (memory.read_u8(d + 0x3e) >> 2) % 2
            parts[#parts + 1] = string.format("slot%d inv=%d sx=%d sy=%d", i, inv,
                memory.read_s16_le(d + 0x20) + memory.read_s16_le(d + 0x24),
                memory.read_s16_le(d + 0x22) + memory.read_s16_le(d + 0x26))
        end
    end
    local s = key .. " | " .. table.concat(parts, "  ")
    if s ~= last then last = s say(string.format("f=%d %s", n, s)) end
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
