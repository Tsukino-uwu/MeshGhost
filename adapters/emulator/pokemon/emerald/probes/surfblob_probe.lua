-- Reads the game's own surf blob (probe, never shipped). The drawn tier paints pixels, so it needs the frame and
-- palette the blob shows for each facing; rather than guess, this logs a line per change from a live blob: the
-- player's facing, the blob's animNum, animCmdIndex, paletteNum, OAM shape and size, images pointer, the resolved
-- image index, and its pos1/pos2 against the rider's (an animNum that never changes means a misread facing map).
-- Cheap enough to leave on while judging the blob. Add it to the loader's target, surf, and face all four ways.

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44

-- Vanilla only: the Archipelago shift is left at 0.
local AVATAR_OFFSET = 0

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function r32(a) return memory.read_u32_le(a) end
local function rs16(a) return memory.read_s16_le(a) end

local function sprAddr(id) return GSPRITES_ADDR + id * SPRITE_SIZE end
local function objAddr(id) return GOBJECTEVENTS_ADDR + AVATAR_OFFSET + id * OBJECTEVENT_SIZE end

local DIRS = { [1] = "south", [2] = "north", [3] = "west", [4] = "east" }

-- gOamMatrices, 32 entries of four s16 (a, b, c, d): matrices 0 and 1 are logged on change, to see whether a moving
-- reflection is drawn affine. For a purely horizontal squeeze only `a` moves, and the drawn width is width * 256 / a.
local GOAMMATRICES = 0x02021bc0
local lastMatrix = nil

local logPath = ("%s/surfblob_probe_%s.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."),
    os.date("%Y%m%d_%H%M%S"))
local logFile = io.open(logPath, "a")
local function say(s)
    console.log("surfblob: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

say("watching for a live surf blob -- surf, then face each direction")

local lastKey = nil

local function tick()
    do
        local m0 = string.format("%d,%d,%d,%d", rs16(GOAMMATRICES + 0), rs16(GOAMMATRICES + 2),
            rs16(GOAMMATRICES + 4), rs16(GOAMMATRICES + 6))
        local m1 = string.format("%d,%d,%d,%d", rs16(GOAMMATRICES + 8), rs16(GOAMMATRICES + 10),
            rs16(GOAMMATRICES + 12), rs16(GOAMMATRICES + 14))
        local k = m0 .. "|" .. m1
        if k ~= lastMatrix then
            lastMatrix = k
            say(string.format("oamMatrix[0]=%s  oamMatrix[1]=%s", m0, m1))
        end
    end

    local objId = r8(GPLAYERAVATAR_ADDR + AVATAR_OFFSET + 0x05)
    if objId > 15 then return end
    local o = objAddr(objId)
    -- fieldEffectSpriteId is how an object event owns its blob; 0 is a valid id, so the sprite must be in use.
    local blobId = r8(o + 0x1a)
    local b = sprAddr(blobId)
    if (r8(b + 0x3e) & 0x01) == 0 or r32(b + 0x1c) == 0 then return end
    -- Surfing only (rider graphic 2 or 92): a jump, a warp and other effects hang off fieldEffectSpriteId too.
    local riderGfx = r8(o + 0x05)
    if riderGfx ~= 2 and riderGfx ~= 92 then return end

    local facing = r8(o + 0x18) & 0x0f
    local animNum, animIdx = r8(b + 0x2a), r8(b + 0x2b)
    local key = string.format("%d/%d/%d", facing, animNum, animIdx)
    if key == lastKey then return end
    lastKey = key

    -- The frame the hardware draws: anims[animNum][animCmdIndex] -> image value, low 16 bits.
    local anims = r32(b + 0x08)
    local images = r32(b + 0x0c)
    local imageIndex, hFlip = -1, false
    if anims ~= 0 then
        local animPtr = r32(anims + animNum * 4)
        if animPtr >= 0x08000000 and animPtr < 0x0a000000 then
            local cmd = r32(animPtr + animIdx * 4)
            imageIndex = cmd & 0xffff
            hFlip = ((cmd >> 22) & 1) == 1
        end
    end

    local rs = r8(GPLAYERAVATAR_ADDR + AVATAR_OFFSET + 0x04)
    local rd = sprAddr(rs)
    say(string.format(
        "facing=%-5s(%d) blobSpr=%3d anim=%d/%d pal=%d oam=%04x %04x images=%08X img=%d flip=%s "
            .. "blob.pos1=%d,%d blob.pos2=%d,%d | rider.pos1=%d,%d rider.pos2=%d,%d sub=%d",
        DIRS[facing] or "?", facing, blobId, animNum, animIdx,
        (r16(b + 0x04) >> 12) & 0x0f, r16(b + 0x00), r16(b + 0x02), images, imageIndex,
        tostring(hFlip),
        rs16(b + 0x20), rs16(b + 0x22), rs16(b + 0x24), rs16(b + 0x26),
        rs16(rd + 0x20), rs16(rd + 0x22), rs16(rd + 0x24), rs16(rd + 0x26),
        r8(b + 0x43)))
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() if logFile then logFile:close() logFile = nil end end
else
    while true do tick() emu.frameadvance() end
end
