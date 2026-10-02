-- Read-only, presses nothing: a moving NPC's step, frame by frame, beside the player's. An NPC is the engine moving
-- a character with its own step machine, which is what a ghost has to look like. It logs when the tile coordinate
-- flips against the pixels and what the sprite's step counters read. It cannot see the NPC's movement type, only
-- the step, and it logs every moving non-player slot, so read the slot column.
local GOBJECTEVENTS_ADDR = 0x02037350
local GPLAYERAVATAR_ADDR = 0x02037590
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44
local MAP_OFFSET = 7
local SLOTS = 16
local FRAMES = 900          -- 15s, then it stops on its own rather than filling a disk

local function r8(a) local ok, v = pcall(memory.read_u8, a) return (ok and v) or 0 end
local function rs16(a) local ok, v = pcall(memory.read_s16_le, a) return (ok and v) or 0 end

local function objAddr(i) return GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE end
local function sprAddr(i) return GSPRITES_ADDR + i * SPRITE_SIZE end

-- data[] starts at 0x2E in struct Sprite (the adapter reads the object-event id there); data[4] is the step speed
-- and data[5] its timer.
local function dataAt(spr, i) return rs16(sprAddr(spr) + 0x2e + i * 2) end

local logfile
do
    local dir = "."
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    logfile = io.open(string.format("%s/npc_step_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
    if logfile then pcall(function() logfile:setvbuf("full", 8192) end) end
end
local function out(msg) if logfile then logfile:write(msg, "\n") end end

out("=== NPC STEP PROBE === one line per frame while any non-player object is mid-step")
out("cols: f | slot tile=x,y pos1=x,y pos2=x,y dir=D speed=S timer=T anim=n/i "
    .. "|| player tile=x,y pos1=x,y pos2=x,y speed=S timer=T anim=n/i")

local frames, prev = 0, {}
MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    if frames > FRAMES then return end
    if frames == FRAMES then
        pcall(console.log, "npc_step_probe: 15s captured, stopping. Log is beside this script.")
        pcall(function() logfile:flush() end)
        return
    end

    local playerObj = r8(GPLAYERAVATAR_ADDR + 0x05)
    local pspr = r8(objAddr(playerObj) + 0x04)
    local pline = string.format(
        "player tile=%d,%d pos1=%d,%d pos2=%d,%d speed=%d timer=%d anim=%d/%d",
        rs16(objAddr(playerObj) + 0x10) - MAP_OFFSET, rs16(objAddr(playerObj) + 0x12) - MAP_OFFSET,
        rs16(sprAddr(pspr) + 0x20), rs16(sprAddr(pspr) + 0x22),
        rs16(sprAddr(pspr) + 0x24), rs16(sprAddr(pspr) + 0x26),
        dataAt(pspr, 4), dataAt(pspr, 5),
        r8(sprAddr(pspr) + 0x2a), r8(sprAddr(pspr) + 0x2b))

    for slot = 0, SLOTS - 1 do
        local o = objAddr(slot)
        local active = (r8(o + 0x00) & 0x01) ~= 0   -- objectEvent.active
        if active and slot ~= playerObj then
            local spr = r8(o + 0x04)
            local x, y = rs16(o + 0x10) - MAP_OFFSET, rs16(o + 0x12) - MAP_OFFSET
            local p2x, p2y = rs16(sprAddr(spr) + 0x24), rs16(sprAddr(spr) + 0x26)
            local key = slot
            local was = prev[key]
            local p1x, p1y = rs16(sprAddr(spr) + 0x20), rs16(sprAddr(spr) + 0x22)
            -- Moving includes pos1: an NPC walks by adding to its sprite's pos1 while pos2 stays 0.
            local moving = (was == nil) or was.x ~= x or was.y ~= y
                or was.p2x ~= p2x or was.p2y ~= p2y or was.p1x ~= p1x or was.p1y ~= p1y
            prev[key] = { x = x, y = y, p2x = p2x, p2y = p2y, p1x = p1x, p1y = p1y }
            if moving and was ~= nil then
                out(string.format(
                    "f=%d slot=%d tile=%d,%d pos1=%d,%d pos2=%d,%d dir=%d speed=%d timer=%d anim=%d/%d || %s",
                    frames, slot, x, y,
                    rs16(sprAddr(spr) + 0x20), rs16(sprAddr(spr) + 0x22), p2x, p2y,
                    r8(o + 0x18) & 0x0f, dataAt(spr, 4), dataAt(spr, 5),
                    r8(sprAddr(spr) + 0x2a), r8(sprAddr(spr) + 0x2b), pline))
            end
        end
    end
end

MESHGHOST_DEV_UNLOAD = function()
    if logfile then
        pcall(function() logfile:flush() end)
        logfile:close()
        logfile = nil
    end
end
