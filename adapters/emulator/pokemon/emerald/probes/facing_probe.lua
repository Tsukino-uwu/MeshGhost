-- MeshGhost -- Emerald: what facing is the ghost actually DRAWN with (PROBE, never shipped)
--
-- WHY. The spawned ghost was reported facing the wrong way while hopping, and the adapter's own
-- HOP log answered the question it was asked -- the object's facingDirection agreed with the peer
-- every time. What a character LOOKS like is not that field: an object event's visible direction
-- is its sprite's ANIMATION NUMBER, plus the hardware flip that turns the west artwork into east.
-- Two facing fixes were reasoned out from the object field and neither landed, which is the point
-- at which this stops being reasoning (CLAUDE.md's two-guesses rule) and becomes a measurement.
--
-- So this reads BOTH characters at the same instant, from the same fields, and prints them on one
-- line: the player and the ghost, object facing and sprite animation side by side. A disagreement
-- between the two COLUMNS names the bug; a disagreement between the two ROWS of the same column
-- names which half of the pipeline dropped it.
--
-- FINDING THE GHOST WITHOUT ASKING THE ADAPTER: a ghost wears LOCALID_PLAYER (255) and is not the
-- player's own object event, which is enough to pick it out of the 16 slots. Nothing here reads an
-- adapter global, so the probe stays honest if the adapter is reloaded underneath it.
--
-- ADDRESSES, from our own make-compare-verified pokeemerald build:
--   gPlayerAvatar 02037590 { spriteId 0x04, objectEventId 0x05 }
--   gObjectEvents 02037350 stride 0x24 { active bit0 of 0x00, localId 0x08, spriteId 0x04,
--                                        facingDirection low nibble of 0x18, movementActionId 0x1C }
--   gSprites      02020630 stride 0x44 { oam 0x00, animNum 0x2A, animCmdIndex 0x2B,
--                                        animPaused bit6 of 0x2C, hFlip bit0 of 0x3F }
--   OAM attr1 bit 12 is hFlip for a non-affine entry.
--
-- HOW TO RUN. Add to dev-scripts/bizhawk-dev-loader-emerald.target beside the adapter, ride the
-- Acro Bike, then read probes/facing_probe_<date>.log. One line per CHANGE, so a held pose is one
-- line rather than a wall.

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local LOCALID_PLAYER = 255

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function objAddr(i) return GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE end
local function sprAddr(i) return GSPRITES_ADDR + i * SPRITE_SIZE end

local DIRS = { [0] = "-", [1] = "down", [2] = "up", [3] = "left", [4] = "right" }

local logPath = ("%s/facing_probe_%s.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."),
    os.date("%Y%m%d_%H%M%S"))
local logFile = io.open(logPath, "a")
local function say(s)
    console.log("facing: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

say("watching the player and the ghost together -- ride the Acro Bike and hop about")

local last = nil
local frame = 0

-- animNum, animCmdIndex, paused, and the flip as the HARDWARE has it -- which is the one that
-- decides what is on screen, and the one a paused sprite can be left holding from an older frame.
local function spriteState(id)
    local d = sprAddr(id)
    return ("anim=%d/%d paused=%d hflipOAM=%d hflipSpr=%d"):format(
        r8(d + 0x2a), r8(d + 0x2b), (r8(d + 0x2c) >> 6) & 1,
        (r16(d + 0x02) >> 12) & 1, r8(d + 0x3f) & 1)
end

local function tick()
    frame = frame + 1
    local pObjId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if pObjId > 15 then return end
    local pa = objAddr(pObjId)

    local ghostObjId = nil
    for i = 0, 15 do
        local a = objAddr(i)
        if i ~= pObjId and (r8(a + 0x00) & 0x01) == 1 and r8(a + 0x08) == LOCALID_PLAYER then
            ghostObjId = i
            break
        end
    end
    if not ghostObjId then return end
    local ga = objAddr(ghostObjId)

    -- FRAME NUMBERED, so the gap between the peer changing action and the ghost adopting it can be
    -- counted rather than eyeballed -- and, more to the point, so it can be watched for DRIFT over
    -- a long hop sequence. A constant gap is the wire; a growing one is a bug in how the ghost's
    -- bounces are re-issued.
    local line = ("f=%-6d P face=%-5s act=%02X %s | G face=%-5s act=%02X %s"):format(frame,
        DIRS[r8(pa + 0x18) & 0x0f] or "?", r8(pa + 0x1c), spriteState(r8(pa + 0x04)),
        DIRS[r8(ga + 0x18) & 0x0f] or "?", r8(ga + 0x1c), spriteState(r8(ga + 0x04)))
    if line ~= last then
        last = line
        say(line)
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() if logFile then logFile:close() logFile = nil end end
else
    while true do tick() emu.frameadvance() end
end
