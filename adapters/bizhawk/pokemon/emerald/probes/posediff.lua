-- MeshGhost -- do the ghost and the player actually hold the same PIXELS? (DEV TOOL, never shipped)
--
-- WHY. Idle on the Acro Bike facing up or down, the user sees the spawned ghost wearing the pose it
-- should only have while rolling along, 2026-08-20 -- and every struct field says otherwise: the
-- anim trace has player and ghost both on animation 5/1, holding it unchanged for 180 frames. When
-- the measurements deny what is on the screen, the measurements are the suspect (`CLAUDE.md`), and
-- the one thing not yet measured is the layer below the fields: the tiles.
--
-- An object event's frames are COPIED into its own OBJ VRAM range when its animation advances. A
-- ghost that is given a new animation number but never a new copy would report the right frame and
-- keep showing the old one -- which is exactly this symptom, and would be invisible to any trace
-- that reads struct fields.
--
-- So: read both tile ranges and count the bytes that differ. Zero means they hold the same picture
-- and the fault is elsewhere; a large number means the ghost is displaying a frame nobody updated.
-- OBJ VRAM starts at 0x06010000 and a 4bpp tile is 32 bytes; tileNum is the low 10 bits of the
-- sprite's OAM attribute 2, which sits at +0x04 of the sprite struct.
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE = 0x24
local SPRITE_SIZE = 0x44
local GHOST_LOCAL_ID = 255
local OBJ_VRAM = 0x06010000
local BYTES = 32 * 32 / 2      -- one 32x32 4bpp frame

local function r8(a) return memory.read_u8(a) end
local function r32(a) return memory.read_u32_le(a) end

local BSLASH = string.char(92)
local logPath = ("%s/posediff_%s.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."),
    os.date("%Y%m%d_%H%M%S"))
local logFile = io.open(logPath, "a")
local function say(s)
    console.log("posediff: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

local function findGhost()
    for i = 0, 15 do
        local a = GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE
        if (r8(a) & 0x01) == 1 and (r8(a + 0x02) & 0x01) == 0 and r8(a + 0x08) == GHOST_LOCAL_ID then
            return a
        end
    end
end

local n, lastLine = 0, nil
local function tick()
    n = n + 1
    -- Every frame now (see below); the compare is 128 reads, well under what one frame copy costs.
    local gObj = findGhost()
    if not gObj then return end
    local pObj = GOBJECTEVENTS_ADDR + r8(GPLAYERAVATAR_ADDR + 0x05) * OBJECTEVENT_SIZE
    local ps = GSPRITES_ADDR + r8(pObj + 0x04) * SPRITE_SIZE
    local gs = GSPRITES_ADDR + r8(gObj + 0x04) * SPRITE_SIZE
    if r8(pObj + 0x05) ~= r8(gObj + 0x05) then return end   -- different graphics: nothing to compare

    local pTile = memory.read_u16_le(ps + 0x04) & 0x3ff
    local gTile = memory.read_u16_le(gs + 0x04) & 0x3ff
    local diff = 0
    for off = 0, BYTES - 4, 4 do
        if r32(OBJ_VRAM + pTile * 32 + off) ~= r32(OBJ_VRAM + gTile * 32 + off) then diff = diff + 4 end
    end
    -- THE HORIZONTAL FLIP TOO. East frames on this graphic are west frames mirrored, so a flip
    -- that disagrees with the animation is a character facing the wrong way for a few frames --
    -- the user, 2026-08-20: the spawned ghost *"flips the sprite in reverse for a bit"*. It lives
    -- in OAM attribute 1, bit 12, and attribute 1 is at +0x02 of the sprite struct.
    local s = string.format(
        "gfx=%d  player anim=%d/%d act=%02X flip=%d | ghost anim=%d/%d act=%02X held=%02X flip=%d "
        .. "| differing: %d of %d",
        r8(pObj + 0x05), r8(ps + 0x2a), r8(ps + 0x2b), r8(pObj + 0x1c),
        (memory.read_u16_le(ps + 0x02) >> 12) & 1,
        r8(gs + 0x2a), r8(gs + 0x2b), r8(gObj + 0x1c), r8(gObj + 0x00),
        (memory.read_u16_le(gs + 0x02) >> 12) & 1, diff, BYTES)
    -- ON CHANGE, not once a second: "wrong right after stopping, right again after a turn" is a
    -- SEQUENCE, and a one-line-per-second sample cannot show the order things happen in. Writing
    -- only when the picture changes keeps the log short while catching every transition.
    if s ~= lastLine then lastLine = s say(string.format("f=%d %s", n, s)) end
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
