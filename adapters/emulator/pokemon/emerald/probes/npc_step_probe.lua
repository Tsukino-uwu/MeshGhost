-- MeshGhost -- Emerald: watch a MOVING NPC's step, frame by frame. PROBE, READ-ONLY.
--
-- Reads game memory and writes none; presses nothing. Safe to leave loaded while judging, unlike
-- anything that drives input.
--
-- WHY. The user, 2026-09-12, after the painted ghost still did not match the player: *"can we look
-- at how a moving npc works?"*. An NPC is the engine moving a character with its own step machine,
-- which is precisely what a ghost has to look like -- so the NPC is the reference, and this is the
-- instrument that reads it.
--
-- WHAT THE DECOMP ALREADY SAYS, so this confirms rather than discovers (CLAUDE.md: read the
-- decompilation first; measurement CONFIRMS what the source says). `NpcTakeStep`
-- (pokeemerald src/event_object_movement.c:8298) walks a fixed table per speed, one entry a frame:
--
--     MOVE_SPEED_NORMAL   16 frames x 1px      walking
--     MOVE_SPEED_FAST_1    8 frames x 2px      running (StartRunningAnim, :5112)
--     MOVE_SPEED_FAST_2    6 frames, 2,3,3,2,3,3   -- deliberately UNEVEN
--     MOVE_SPEED_FASTER    4 frames x 4px
--     MOVE_SPEED_FASTEST   2 frames x 8px
--
-- So the questions this probe answers on a live NPC are the ones the table cannot: WHEN the tile
-- coordinate flips relative to the pixels (they hand over on different frames, which is the whole
-- of this adapter's paint history), and what the sprite's own step counters read while it happens.
--
-- WHAT IT CANNOT SEE: which movement TYPE the NPC was given (wander, pace, follow), only the step
-- it is taking. And it reports the first moving non-player object it finds each frame -- with two
-- NPCs walking at once it will follow whichever comes first in the array, so read the slot column
-- rather than assuming it stayed on one character.
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

-- `data[0]` sits at 0x2E in struct Sprite -- the adapter reads the object-event id there, which is
-- what pins this offset. So the step counters `NpcTakeStep` uses, data[4] (speed) and data[5]
-- (timer), are 0x36 and 0x38. Reading them is how a live NPC states its own cadence rather than
-- having one inferred from its pixels.
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
            -- MOVING HAS TO INCLUDE pos1, and the first version's omission is worth keeping as a
            -- warning: it tested only the TILE and pos2, and a walking NPC holds pos2 at 0 the
            -- whole way -- the engine moves an NPC by adding to the SPRITE's pos1, one pixel a
            -- frame (`Step1`). So the probe logged one frame in sixteen, which looks exactly like
            -- an NPC that teleports a tile at a time, and would have "confirmed" a cadence nobody
            -- has. A filter applied before you look is a guess about the answer.
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
