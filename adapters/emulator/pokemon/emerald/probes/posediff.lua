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
local GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR = 0x08505620

-- THE FRAME SIZE COMES FROM THE GRAPHIC, not from a constant -- read, rather than derived from the
-- graphic's dimensions. Each graphics-info struct states its own byte count at +0x06, and that is
-- the number the engine itself copies with, so it is the right span to compare whatever the graphic.
-- (Measured: the plain walker reports 512, the same as a bike -- the width alone would have said 256.)

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
    local bytes = 512
    do
        local ptr = memory.read_u32_le(GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR + r8(pObj + 0x05) * 4)
        if ptr >= 0x08000000 and ptr < 0x0a000000 then
            local s = memory.read_u16_le(ptr + 0x06)
            if s > 0 and s <= 2048 then bytes = s end
        end
    end
    local diff = 0
    for off = 0, bytes - 4, 4 do
        if r32(OBJ_VRAM + pTile * 32 + off) ~= r32(OBJ_VRAM + gTile * 32 + off) then diff = diff + 4 end
    end

    -- AGAINST THE ROM, WITH THE PLAYER TAKEN OUT OF IT. Every number above compares the ghost to
    -- the PLAYER's tiles, and the player's tile number reads 0 -- which is what you see if their
    -- sprite draws through its subsprite table with its own OAM entry parked. If that is so, every
    -- reading in this probe has been measured against the wrong bytes, including the zeros that
    -- made earlier fixes look right.
    --
    -- The ROM frame owes nothing to either sprite: resolve (animation, index) through the
    -- graphic's own anims table to an image index, and compare the ghost's tiles against those
    -- exact pixels. Done twice -- once for the frame the GHOST's own fields name, once for the
    -- frame the PLAYER is on -- which separates "the copy did not land" from "we asked for the
    -- wrong frame".
    local function romDiff(animNum, animIdx)
        local ptr = memory.read_u32_le(GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR + r8(gObj + 0x05) * 4)
        if ptr < 0x08000000 or ptr >= 0x0a000000 then return -1 end
        local anims, images = r32(ptr + 0x18), r32(ptr + 0x1c)
        if anims < 0x08000000 or images < 0x08000000 then return -1 end
        local animPtr = r32(anims + animNum * 4)
        if animPtr < 0x08000000 or animPtr >= 0x0a000000 then return -1 end
        local frame = r32(animPtr + animIdx * 4) & 0xFFFF
        local src = r32(images + frame * 8)
        if src < 0x08000000 or src >= 0x0a000000 then return -1 end
        local d = 0
        for off = 0, bytes - 4, 4 do
            if r32(OBJ_VRAM + gTile * 32 + off) ~= r32(src + off) then d = d + 4 end
        end
        return d
    end
    local romOwn = romDiff(r8(gs + 0x2a), r8(gs + 0x2b))
    local romPlayer = romDiff(r8(ps + 0x2a), r8(ps + 0x2b))
    -- THE HORIZONTAL FLIP TOO. East frames on this graphic are west frames mirrored, so a flip
    -- that disagrees with the animation is a character facing the wrong way for a few frames --
    -- the user, 2026-08-20: the spawned ghost *"flips the sprite in reverse for a bit"*. It lives
    -- in OAM attribute 1, bit 12, and attribute 1 is at +0x02 of the sprite struct.
    local s = string.format(
        "gfx=%d  player anim=%d/%d act=%02X flip=%d P2c=%02X | ghost anim=%d/%d act=%02X held=%02X flip=%d G2c=%02X G3f=%02X Gb1=%02X "
        .. "| differing: %d of %d",
        r8(pObj + 0x05), r8(ps + 0x2a), r8(ps + 0x2b), r8(pObj + 0x1c),
        (memory.read_u16_le(ps + 0x02) >> 12) & 1, r8(ps + 0x2c),
        r8(gs + 0x2a), r8(gs + 0x2b), r8(gObj + 0x1c), r8(gObj + 0x00),
        (memory.read_u16_le(gs + 0x02) >> 12) & 1, r8(gs + 0x2c), r8(gs + 0x3f), r8(gObj + 0x01), diff, bytes)
        .. string.format(" | ghost vs ROM: own=%d player=%d", romOwn, romPlayer)
        -- SHAPE AND SIZE, which decide how many tiles the hardware reads and in what arrangement.
        -- Identical animation state with different pixels has to be explained by something below
        -- the animation, and the obvious candidate is a ghost still being drawn as the 32-wide bike
        -- it just got off. Shape is bits 14-15 of OAM attribute 0, size the same bits of attribute
        -- 1; together they name the sprite's dimensions. Subsprite mode lives at +0x42.
        -- AND WHERE EACH IS DRAWN. Mounting looks steady on the player and the painted copy and
        -- shaky on the spawned one, so the question is a position one: pos1 is the sprite's own
        -- coordinate, pos2 the per-frame offset the engine adds during a step, and centerToCorner
        -- the shift that comes from the graphic's own dimensions -- which is exactly what changes
        -- when a 16-wide walker becomes a 32-wide bike.
        .. string.format(" | ppos=%d,%d+%d,%d c2c=%d,%d | gpos=%d,%d+%d,%d c2c=%d,%d",
            memory.read_s16_le(ps + 0x20), memory.read_s16_le(ps + 0x22),
            memory.read_s16_le(ps + 0x24), memory.read_s16_le(ps + 0x26),
            memory.read_s8(ps + 0x28), memory.read_s8(ps + 0x29),
            memory.read_s16_le(gs + 0x20), memory.read_s16_le(gs + 0x22),
            memory.read_s16_le(gs + 0x24), memory.read_s16_le(gs + 0x26),
            memory.read_s8(gs + 0x28), memory.read_s8(gs + 0x29))
        .. string.format(" | player sh=%d sz=%d sub=%02X | ghost sh=%d sz=%d sub=%02X",
            (memory.read_u16_le(ps + 0x00) >> 14) & 3, (memory.read_u16_le(ps + 0x02) >> 14) & 3,
            r8(ps + 0x42),
            (memory.read_u16_le(gs + 0x00) >> 14) & 3, (memory.read_u16_le(gs + 0x02) >> 14) & 3,
            r8(gs + 0x42))
    -- ON CHANGE, not once a second: "wrong right after stopping, right again after a turn" is a
    -- SEQUENCE, and a one-line-per-second sample cannot show the order things happen in. Writing
    -- only when the picture changes keeps the log short while catching every transition.
    if s ~= lastLine then lastLine = s say(string.format("f=%d %s", n, s)) end
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
