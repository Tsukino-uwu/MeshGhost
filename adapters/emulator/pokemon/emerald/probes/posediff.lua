-- Do the ghost and the player hold the same pixels (dev tool, never shipped)? An object event's frame is copied
-- into its own OBJ VRAM range when its animation advances, so a ghost can report the right frame and show an old
-- one, invisible to any trace of struct fields. This counts the bytes that differ between the two tile ranges
-- (OBJ VRAM at 0x06010000, 32 bytes a 4bpp tile, tileNum the low 10 bits of OAM attribute 2 at sprite +0x04).
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE = 0x24
local SPRITE_SIZE = 0x44
local GHOST_LOCAL_ID = 255
local OBJ_VRAM = 0x06010000
local GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR = 0x08505620

-- The frame size is the graphics info's own byte count at +0x06, the span the engine copies with, whatever the
-- graphic's dimensions.

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
    -- Every frame: the compare is 128 reads.
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

    -- Also against the ROM frame, owed nothing by either sprite: (animation, index) resolved through the graphic's
    -- anims table, for the frame the ghost's fields name and the one the player is on. That separates "the copy
    -- did not land" from "we asked for the wrong frame", and does not lean on the player's tile number.
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
    -- The horizontal flip, OAM attribute 1 bit 12 (+0x02): east frames are west frames mirrored.
    local s = string.format(
        "gfx=%d  player anim=%d/%d act=%02X flip=%d P2c=%02X | ghost anim=%d/%d act=%02X held=%02X flip=%d G2c=%02X G3f=%02X Gb1=%02X "
        .. "| differing: %d of %d",
        r8(pObj + 0x05), r8(ps + 0x2a), r8(ps + 0x2b), r8(pObj + 0x1c),
        (memory.read_u16_le(ps + 0x02) >> 12) & 1, r8(ps + 0x2c),
        r8(gs + 0x2a), r8(gs + 0x2b), r8(gObj + 0x1c), r8(gObj + 0x00),
        (memory.read_u16_le(gs + 0x02) >> 12) & 1, r8(gs + 0x2c), r8(gs + 0x3f), r8(gObj + 0x01), diff, bytes)
        .. string.format(" | ghost vs ROM: own=%d player=%d", romOwn, romPlayer)
        -- Shape (bits 14-15 of attribute 0) and size (the same bits of attribute 1) name the dimensions, subsprite
        -- mode is +0x42; then pos1, pos2 and centerToCorner, which change when a 16-wide walker becomes a 32-wide bike.
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
    -- On change: a fault that comes and goes is a sequence, and a once-a-second sample loses the order.
    if s ~= lastLine then lastLine = s say(string.format("f=%d %s", n, s)) end
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
