-- MeshGhost -- Mach Bike run-up and climb, repeating (DEV TOOL, never shipped)
--
-- WHY. The Mach Bike's whole purpose is the muddy slope: hold a direction into it at top speed and
-- you climb, drop below that speed and the slope pushes you back down. Holding one key for minutes
-- while watching two ghosts for defects is exactly what a script should do instead of the user
-- (agent_docs/playing.md).
--
-- THE RUN-UP IS THE POINT. Held from a standing start one tile below the mud, the bike never
-- accelerates at all: ForcedMovement_MuddySlope (src/field_player_avatar.c:567-581) resets the
-- speed counter and pushes the rider back south the moment they are on the slope below
-- PLAYER_SPEED_FASTEST, so it gains a tile and loses it, once a second, forever -- measured, and
-- the reason `speed=0 peak=0` appeared in every line of the hold-Up log.
--
-- So the ride does what a player does (user, 2026-08-20): back off 3 tiles, then hold Up all the
-- way, arriving at the mud already at top speed. Repeating, so the climb can be watched more than
-- once without anyone touching the pad.
--
-- Both phases are counted in TILES and the climb ends when the mud does, not at a guessed number --
-- the slope's length is a property of the slope. Each phase logs the speed it actually reached and
-- how many frames it spent on mud, so "held the key" and "climbed the slope" stay separate claims
-- (MB_MUDDY_SLOPE = 208, include/constants/metatile_behaviors.h).
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GBACKUPMAPLAYOUT = 0x03005dc0
local GMAPHEADER = 0x02037318
local MB_MUDDY_SLOPE = 208



local function behaviourAt(x, y)
    local w = memory.read_s32_le(GBACKUPMAPLAYOUT)
    local map = memory.read_u32_le(GBACKUPMAPLAYOUT + 0x08)
    if map == 0 or w <= 0 then return nil end
    local id = memory.read_u16_le(map + (x + w * y) * 2) & 0x03ff
    local layout = memory.read_u32_le(GMAPHEADER)
    if layout == 0 then return nil end
    local ts, ix
    if id < 512 then ts, ix = memory.read_u32_le(layout + 0x10), id
    else ts, ix = memory.read_u32_le(layout + 0x14), id - 512 end
    if ts == 0 then return nil end
    local attrs = memory.read_u32_le(ts + 0x10)
    if attrs == 0 then return nil end
    return memory.read_u16_le(attrs + ix * 2) & 0xff
end

local BACK_OFF_TILES = 3
local MIN_CLIMB_TILES = 2
local PHASE_FRAME_CAP = 500

local phase, startY, frames, peak, mud, climbs, stopped = "down", nil, 0, 0, 0, 0, false
local function say(s) console.log("bikeclimb: " .. s) end
local function r8(a) return memory.read_u8(a) end

local function tick()
    if stopped then return end
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or r8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then
        stopped = true
        joypad.set({})
        say("STOPPED (the player is not ours to move) -- keys released")
        return
    end

    local objId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return end
    local o = GOBJECTEVENTS_ADDR + objId * 0x24
    local x = memory.read_s16_le(o + 0x10)
    local y = memory.read_s16_le(o + 0x12)
    if not startY then
        startY = y
        say(string.format("from (%d,%d): back off %d tiles, then climb", x, y, BACK_OFF_TILES))
    end

    local speed = r8(GPLAYERAVATAR_ADDR + 0x0b)
    if speed > peak then peak = speed end
    local here = behaviourAt(x, y)
    if here == MB_MUDDY_SLOPE then mud = mud + 1 end
    frames = frames + 1

    if phase == "down" then
        if (y - startY) >= BACK_OFF_TILES or frames >= PHASE_FRAME_CAP then
            say(string.format("backed off to (%d,%d) in %d frames -- now climbing", x, y, frames))
            phase, startY, frames, peak, mud = "up", y, 0, 0, 0
            return
        end
        joypad.set({ Down = true })
    else
        local gained = startY - y
        -- Off the mud and past the minimum: the slope is cleared.
        if (gained >= MIN_CLIMB_TILES and here ~= MB_MUDDY_SLOPE and mud > 0)
            or frames >= PHASE_FRAME_CAP
        then
            climbs = climbs + 1
            say(string.format("climb %d %s at (%d,%d): gained %d tiles in %d frames, %d on mud, "
                .. "peak bikeSpeed %d", climbs,
                (mud > 0 and here ~= MB_MUDDY_SLOPE) and "CLEARED" or "FAILED",
                x, y, gained, frames, mud, peak))
            phase, startY, frames, peak, mud = "down", y, 0, 0, 0
            return
        end
        joypad.set({ Up = true })
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) say("unloaded, keys released") end
else
    while true do tick() emu.frameadvance() end
end
