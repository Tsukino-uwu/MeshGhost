-- MeshGhost — Emerald: what facing the ghost is drawn with (dev tool, read-only). Load it beside the adapter and ride
-- the Acro Bike: a visible direction is the sprite's animation number plus the flip, not the object's facingDirection.

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

-- Both flips: the OAM one decides what is on screen, and a paused sprite can hold it from an older frame.
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

    -- The ghost is an active localId 255 that is not the player's object: no adapter global for a reload to skew.
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

    -- Frame numbered, so the gap before the ghost adopts a peer's action can be counted: a constant gap is the wire,
    -- a growing one a bug in how the ghost's bounces are re-issued.
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
