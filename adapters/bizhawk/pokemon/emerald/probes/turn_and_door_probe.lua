-- MeshGhost — Emerald turn/door probe (DEVELOPMENT TOOL, never shipped)
--
-- WHY
-- Two gaps the side-by-side comparison (MESHGHOST_COMPARE_TIERS) turned up, both about what the
-- ENGINE does that our painted renderer does not:
--
--   1. "the drawn one is not doing facing animations when standing still" -- turning on the spot
--      arrives as anim=idle with a new orientation, and the drawn tier paints one static idle
--      frame for it. What the engine plays for a spawned ghost instead is what this measures.
--   2. "the drawn one is shown a bit during the transition into a house" -- the engine's own
--      characters are gone for that moment and ours is not. How many frames that lasts, and what
--      the engine's own player sprite is doing meanwhile, decides what the drawn tier should
--      wait for. NOT a fade length picked from memory.
--
-- WRITES TO A FILE, NEVER TO THE CONSOLE, AND NEVER PER FRAME TO DISK.
-- The first attempt at this measurement was a per-frame console.log and the user's next words
-- were "its spamming the console lag, and the game is lagging" (2026-08-19). BizHawk's Lua
-- console is expensive; a diagnostic that costs frames measures a game that is not the one being
-- played. So: samples accumulate in a table and are flushed once a second, and every line is a
-- CHANGE rather than a heartbeat.
--
-- ADDRESSES: taken from meshghost_emerald.lua, which measured them -- nothing here is new, and
-- nothing is written. Vanilla only (avatarAddrOffset 0); on a patched ROM the adapter's own
-- detection is what shifts these, and this probe would need the same treatment.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44

local LOG_PATH = "C:/dev/MeshGhost/adapters/bizhawk/pokemon/emerald/probes/turn_and_door_probe.log"
local logfile = io.open(LOG_PATH, "a")
local pending, frames, last = {}, 0, nil

local function say(m)
    pending[#pending + 1] = m
end

local function u8(a) return memory.read_u8(a) end

-- The whole per-frame sample, as one comparable string. Everything in it is something the drawn
-- tier could in principle mirror: what the player's own sprite is animating, which way the object
-- event faces, and how many characters the engine currently has on the map at all.
local function sample()
    local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if base == 0 then return "no save block (title/intro)" end

    local flags = u8(GPLAYERAVATAR_ADDR + 0x00)
    local runningState = u8(GPLAYERAVATAR_ADDR + 0x02)
    local objectEventId = u8(GPLAYERAVATAR_ADDR + 0x05)
    local objAddr = GOBJECTEVENTS_ADDR + objectEventId * OBJECTEVENT_SIZE
    local facing = memory.read_u16_le(objAddr + 0x18) & 0xF
    local spr = GSPRITES_ADDR + u8(GPLAYERAVATAR_ADDR + 0x04) * SPRITE_SIZE

    local active = 0
    for i = 0, 15 do
        if (u8(GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE) & 0x01) == 1 then active = active + 1 end
    end

    return string.format(
        "map=%d:%d pos=%d,%d facing=%d run=%d avatarFlags=%02X sprAnim=%d/%d sprFlags=%02X "
            .. "sprXY=%d,%d pos2=%d,%d coordOff=%d,%d camPix=%d,%d origin=%d,%d "
            .. "activeObjects=%d",
        memory.read_s8(base + 0x04), memory.read_s8(base + 0x05),
        memory.read_s16_le(base + 0x00), memory.read_s16_le(base + 0x02),
        facing, runningState, flags,
        u8(spr + 0x2a), u8(spr + 0x2b), u8(spr + 0x3e),
        memory.read_s16_le(spr + 0x20), memory.read_s16_le(spr + 0x22),
        -- Which frame the hardware is actually showing, and which image struct the engine chose:
        -- between them they name the frame a turn draws, which is the thing the drawn tier has to
        -- mirror and the one thing the animation NUMBER does not say.
        -- THE ANCHOR QUESTION. A drawn ghost is placed relative to the local player, so the
        -- anchor it is placed against has to move exactly as the engine moves the world. Ours is
        -- the adapter's own SMOOTHED estimate of the player, and the residual chop while RUNNING
        -- points straight at it. The engine's own scroll is gTotalCameraPixelOffset, so if
        -- (player sprite pixel + camera pixel offset) is CONSTANT while running, that sum is an
        -- exact anchor and the smoothing can be taken out of the path entirely. If it wobbles,
        -- it is not, and the fourth attempt should not be built on it either.
        -- pos2 is the engine's OWN sub-tile step offset for a sprite, and coordOffset is what
        -- playerScreenPos already adds. If (screen position - pos2) is the screen position of the
        -- player's TILE, it must hold still within a step and move by exactly 16 when the tile
        -- counter changes -- in EVERY direction. Reconstructing that offset from the camera
        -- counter instead was right going down and left and a whole tile out going up and right
        -- ("looks horrible when running up or right"), which is what this settles.
        memory.read_s16_le(spr + 0x24), memory.read_s16_le(spr + 0x26),
        memory.read_s16_le(0x02021bbc), memory.read_s16_le(0x02021bbe),
        memory.read_s16_le(0x03005dec), memory.read_s16_le(0x03005de8),
        memory.read_s16_le(spr + 0x20) + memory.read_s16_le(spr + 0x24)
            + memory.read_s8(spr + 0x28) + memory.read_s16_le(0x02021bbc)
            - memory.read_s16_le(spr + 0x24),
        memory.read_s16_le(spr + 0x22) + memory.read_s16_le(spr + 0x26)
            + memory.read_s8(spr + 0x29) + memory.read_s16_le(0x02021bbe)
            - memory.read_s16_le(spr + 0x26),
        active)
end

say("=== turn/door probe start ===")

MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    local s = sample()
    if s ~= last then
        last = s
        say(string.format("f=%d %s", frames, s))
    end
    -- Once a second, not once a frame: the write is what costs, not the reads.
    if frames % 60 == 0 and #pending > 0 and logfile then
        logfile:write(table.concat(pending, "\n"), "\n")
        logfile:flush()
        pending = {}
    end
end

MESHGHOST_DEV_UNLOAD = function()
    if logfile then
        if #pending > 0 then logfile:write(table.concat(pending, "\n"), "\n") end
        logfile:write("=== turn/door probe stop ===\n")
        logfile:close()
        logfile = nil
    end
end
