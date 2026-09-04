-- MeshGhost -- Mach Bike up and down a slope, by TILES (DEV TOOL, never shipped)
--
-- WHY. The Mach Bike exists to climb a MUDDY SLOPE: at anything below top speed the slope slides
-- the rider back down, so it is the one terrain that exercises acceleration, top speed, and being
-- pushed backwards while still holding a direction -- all the things a ghost has to mirror. Riding
-- it by hand while also watching two ghosts for defects is not something a person can hold steady
-- (agent_docs/playing.md, "Drive the game YOURSELF before asking").
--
-- ROUTE (user, 2026-08-20): about 4-5 tiles up, then 4-5 back down, repeating.
--
-- COUNTED IN TILES, with a per-leg frame cap. Tiles, because a fixed frame count covers a
-- different distance depending on the speed reached and drifts the run across the map (that is how
-- an earlier square wandered into a trainer). A cap as well, because on this terrain failing to
-- gain ground is a REAL OUTCOME rather than a fault: too slow up a muddy slope and the game slides
-- you back, forever if it likes. The cap ends the leg and the log says how far it actually got.
--
-- It reports the metatile behaviour under the player each leg, so "the test ran" and "the test ran
-- ON THE SLOPE" stay different claims -- MB_MUDDY_SLOPE is 208 (include/constants/metatile_behaviors.h,
-- enum from 0; cross-checked against MB_POND_WATER 16, which this repo measured independently).
--
-- Addresses copied from meshghost_emerald.lua, never from memory.

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GBACKUPMAPLAYOUT = 0x03005dc0
local GMAPHEADER = 0x02037318
local MB_MUDDY_SLOPE = 208

-- Eight rather than five, and DOWN first: the mud on this map sits below where the ride starts
-- (user, 2026-08-20 -- *"need to go a bit further down again to get to the mud"*), and a five-tile
-- leg settled into a stretch with none of it, logging "0 of them on mud" lap after lap.
local TILES_PER_LEG = 8
local LEG_FRAME_CAP = 400   -- generous: a failed climb is an outcome, not a hang
-- CLIMB UNTIL THE MUD ENDS, rather than a guessed number of tiles. Five was not clearing the slope
-- (user, 2026-08-20: *"its going up on the mud, just not getting up far enough"*), and the right
-- length is a property of the slope, not something to tune: the leg ends once the player is past
-- TILES_PER_LEG *and* standing on something that is no longer MB_MUDDY_SLOPE. The frame cap still
-- ends a climb that never makes it, which on this terrain is a real outcome worth logging.

local leg = { { key = "Down", delta = 1 }, { key = "Up", delta = -1 } }
local which, startY, frames, laps, peak, stopped = 1, nil, 0, 0, 0, false
local mudFrames, bestGain = 0, 0

local function say(s) console.log("bikeline: " .. s) end
local function r8(a) return memory.read_u8(a) end

local function controllable()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1 then return false, "not the overworld" end
    if r8(GPLAYERAVATAR_ADDR + 0x06) ~= 0 then return false, "a script has the player" end
    return true
end

local function playerXY()
    local objId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return nil end
    local o = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
    return memory.read_s16_le(o + 0x10), memory.read_s16_le(o + 0x12)
end

-- The behaviour under a grid coordinate, so the log can say whether this is the slope at all.
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

local function tick()
    if stopped then return end
    local ok, why = controllable()
    if not ok then
        stopped = true
        joypad.set({})
        say("STOPPED (" .. why .. ") -- keys released")
        return
    end

    local x, y = playerXY()
    if not x then return end

    if not startY then
        startY = y
        local b = behaviourAt(x, y)
        say(string.format("riding from (%d,%d): %d up, %d down, repeating -- behaviour here = %s%s",
            x, y, TILES_PER_LEG, TILES_PER_LEG, tostring(b),
            b == MB_MUDDY_SLOPE and " (MUDDY SLOPE)" or " (NOT the muddy slope)"))
    end

    local speed = r8(GPLAYERAVATAR_ADDR + 0x0b)
    if speed > peak then peak = speed end

    local s = leg[which]
    local moved = (y - startY) * s.delta
    frames = frames + 1

    local here = behaviourAt(x, y)
    if here == MB_MUDDY_SLOPE then mudFrames = mudFrames + 1 end
    if moved > bestGain then bestGain = moved end

    -- Up: past the minimum AND off the mud. Down: the plain tile count is right, since coming back
    -- down a slope needs no speed.
    local doneLeg
    if s.key == "Up" then
        doneLeg = moved >= TILES_PER_LEG and here ~= MB_MUDDY_SLOPE
    else
        doneLeg = moved >= TILES_PER_LEG
    end

    if doneLeg or frames >= LEG_FRAME_CAP then
        say(string.format("%s leg %s at (%d,%d): gained %d tiles (best %d) in %d frames, "
            .. "%d of them on mud, peak bikeSpeed %d, behaviour now %s",
            s.key, doneLeg and "done" or "CAPPED", x, y, moved, bestGain, frames, mudFrames,
            peak, tostring(here)))
        which = which + 1
        if which > #leg then which, laps = 1, laps + 1 say("lap " .. laps .. " done") end
        startY, frames, peak, mudFrames, bestGain = y, 0, 0, 0, 0
        return -- one frame with no key held, so the turn reads as a turn
    end

    joypad.set({ [s.key] = true })
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) say("unloaded, keys released") end
else
    while true do tick() emu.frameadvance() end
end
