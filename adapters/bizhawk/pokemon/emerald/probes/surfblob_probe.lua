-- MeshGhost — Pokémon Emerald: read the game's own surf blob (PROBE, never shipped)
--
-- WHY
-- The spawned tier builds a ghost's blob from the field effect's ROM template and hands it to
-- `UpdateSurfBlobFieldEffect`, so the engine drives it and nothing needs to be known about how it
-- animates. The DRAWN tier has no engine to hand it to: it paints pixels, so it needs the frame
-- the blob would be showing, in the palette it would be showing it in — which means knowing which
-- animation number goes with which way the rider is facing, and which palette slot the blob's
-- tiles resolve to.
--
-- Both of those are guessable and neither is worth guessing (`_template/probes.md`, and the two
-- earlier blob attempts that put it a tile low and dark navy). The game has a live blob on screen
-- the moment anybody surfs, so this reads that one instead: one line per direction change,
-- carrying what the engine chose for that facing.
--
-- WHAT IT PRINTS, per sample: the player's facing, and from the blob sprite — `animNum`,
-- `animCmdIndex`, `paletteNum`, the OAM shape/size bits, the `images` pointer it is drawing from,
-- the resolved image index for the frame on screen, and its `pos1`/`pos2` against the rider's. The
-- image index and the palette slot are the two the drawn tier actually needs; the rest is there to
-- catch a misread (a blob that never changes animNum means the facing map is not what is being
-- asked for).
--
-- ADDRESSES, from our own make-compare-verified pokeemerald build — the same ones the adapter uses
-- and traceable to it rather than to memory:
--   gPlayerAvatar   02037590  { objectEventId 0x05, spriteId 0x04 }
--   gObjectEvents   02037350  stride 0x24, fieldEffectSpriteId at 0x1A, facingDirection in 0x18
--   gSprites        02020630  stride 0x44
--   struct Sprite: oam 0x00, images 0x0C, pos1 0x20, pos2 0x24, animNum 0x2A, animCmdIndex 0x2B
--
-- COST. One read set per frame and a write only when the facing changes, so it is cheap enough to
-- leave on while judging the blob itself — but it is still a probe: it is off unless it is in the
-- loader's target list, and it never ships.
--
-- HOW TO RUN
--   Add this file to dev-scripts/bizhawk-dev-loader-emerald.target, then surf and face each of the
--   four directions. It writes probes/surfblob_probe_<date>.log and says so in the console.

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44

-- The Archipelago shift, so the probe works on a patched seed as well as a vanilla one. The
-- adapter measures this properly; here the vanilla case is the one being used, and a patched ROM
-- simply reports nothing rather than reading a wrong address and printing plausible numbers.
local AVATAR_OFFSET = 0

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function r32(a) return memory.read_u32_le(a) end
local function rs16(a) return memory.read_s16_le(a) end

local function sprAddr(id) return GSPRITES_ADDR + id * SPRITE_SIZE end
local function objAddr(id) return GOBJECTEVENTS_ADDR + AVATAR_OFFSET + id * OBJECTEVENT_SIZE end

local DIRS = { [1] = "south", [2] = "north", [3] = "west", [4] = "east" }

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
    local objId = r8(GPLAYERAVATAR_ADDR + AVATAR_OFFSET + 0x05)
    if objId > 15 then return end
    local o = objAddr(objId)
    -- fieldEffectSpriteId is how an object event owns its blob (documentation.md's surfing
    -- section). 0 is also a valid sprite id, so the blob is confirmed by the sprite being in use
    -- with a callback, not by the id alone.
    local blobId = r8(o + 0x1a)
    local b = sprAddr(blobId)
    if (r8(b + 0x3e) & 0x01) == 0 or r32(b + 0x1c) == 0 then return end
    -- The rider's own graphic says whether this is surfing at all: a jump, a warp and a few other
    -- effects also hang off fieldEffectSpriteId, and their sprites would answer every question
    -- here with a number that looks fine.
    local riderGfx = r8(o + 0x05)
    if riderGfx ~= 2 and riderGfx ~= 92 then return end

    local facing = r8(o + 0x18) & 0x0f
    local animNum, animIdx = r8(b + 0x2a), r8(b + 0x2b)
    local key = string.format("%d/%d/%d", facing, animNum, animIdx)
    if key == lastKey then return end
    lastKey = key

    -- Resolve the frame the hardware is actually drawing, the same three ROM reads the drawn tier
    -- makes: anims[animNum][animCmdIndex] -> imageValue, low 16 bits (include/sprite.h).
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
