-- MeshGhost -- Pokemon Emerald: ride a fixed square, by TILES (DEV TOOL, never shipped)
--
-- WHY
-- The bike work needs a peer that moves and turns repeatably while both renderers are watched, and
-- that is not something a person can hold steady while also looking for defects
-- (agent_docs/playing.md, "Drive the game YOURSELF before asking"). So the riding is scripted.
--
-- COUNTED IN TILES, NOT FRAMES, and that is the whole design. The first version held each
-- direction for a fixed number of frames, which covers a different DISTANCE depending on how far
-- the bike has accelerated -- so the square drifted across the map every lap and eventually rode
-- into a trainer, twice, and the user had to fight one. Counting the player's own coordinates pins
-- the route to the patch it started on however fast the bike happens to be going.
--
-- ROUTE (user, 2026-08-20): 3 tiles up, 3 left, 3 down, 3 right, looping, from wherever it starts.
-- Short sides on purpose: they keep the ride inside a safe town patch with no tall grass and no
-- trainer sightlines. Note the cost -- a Mach Bike accelerates over distance (PlayerWalkNormal ->
-- Fast -> Faster, pokeemerald src/bike.c:75-80), so three tiles may never reach top speed. The
-- animation cases show at any speed; the top-speed catch-up case may not reproduce here, and the
-- log reports the speeds actually reached rather than assuming a held key produced them.
--
-- SAFE BY CONSTRUCTION, because guards alone were not enough: an earlier abort test asked only
-- whether CB2_Overworld was the active callback, and that stays true while a trainer's approach
-- script runs -- so it kept holding a direction into an encounter. This one also tests
-- preventStep, and never sends a direction outside the overworld at all (in a battle a direction
-- moves the cursor onto POKeMON, which is how a scripted ride ends up swapping the user's party).
--
-- ADDRESSES: copied from meshghost_emerald.lua, never from memory -- two written from recall
-- earlier today were both wrong.
--   gPlayerAvatar   02037590  { objectEventId 0x05, preventStep 0x06, bikeSpeed 0x0B }
--   gObjectEvents   02037350  stride 0x24, currentCoords x 0x10 / y 0x12
--   gMain.callback2 030022C4, CB2_Overworld 08085E5C
--
-- HOW TO RUN: add to dev-scripts/bizhawk-dev-loader-emerald.target. Dropping it releases the keys.

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

local TILES_PER_SIDE = 3
-- Held direction, and the axis and sign it advances the player's coordinate on.
local SIDES = {
    { key = "Up",    axis = "y", delta = -1 },
    { key = "Left",  axis = "x", delta = -1 },
    { key = "Down",  axis = "y", delta =  1 },
    { key = "Right", axis = "x", delta =  1 },
}

-- A step at the slowest speed is 16 frames, so this only trips on a genuine block (a wall, an NPC,
-- a ledge) and not on ordinary slow movement.
local STUCK_FRAMES = 100

local side, sideStartX, sideStartY = 1, nil, nil
local stuckFor, lastX, lastY = 0, nil, nil
local laps, peak, stopped = 0, 0, false

local function say(s) console.log("bikeloop: " .. s) end
local function r8(a) return memory.read_u8(a) end

local function controllable()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1 then
        return false, "not the overworld"
    end
    -- preventStep is set while a script owns the player -- a trainer's approach, a sign, a warp.
    -- This is the term the callback test alone was missing.
    if r8(GPLAYERAVATAR_ADDR + 0x06) ~= 0 then return false, "a script has the player" end
    return true
end

local function playerXY()
    local objId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return nil end
    local o = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
    return memory.read_s16_le(o + 0x10), memory.read_s16_le(o + 0x12)
end

local function halt(why)
    if stopped then return end
    stopped = true
    joypad.set({})
    say("STOPPED (" .. why .. ") -- keys released")
end

local function tick()
    if stopped then return end

    local ok, why = controllable()
    if not ok then halt(why) return end

    local x, y = playerXY()
    if not x then return end

    if not sideStartX then
        sideStartX, sideStartY, lastX, lastY = x, y, x, y
        say(string.format("riding from (%d,%d): 3 up, 3 left, 3 down, 3 right, looping", x, y))
    end

    local speed = r8(GPLAYERAVATAR_ADDR + 0x0b)
    if speed > peak then peak = speed end

    -- Blocked: the coordinate is not advancing although a direction is held. Grinding into a wall
    -- for the rest of the session teaches nothing, so say where and stop.
    if x == lastX and y == lastY then
        stuckFor = stuckFor + 1
        if stuckFor > STUCK_FRAMES then
            halt(string.format("blocked at (%d,%d) heading %s", x, y, SIDES[side].key))
            return
        end
    else
        stuckFor = 0
        lastX, lastY = x, y
    end

    local s = SIDES[side]
    local moved = (s.axis == "x") and (x - sideStartX) or (y - sideStartY)
    if moved * s.delta >= TILES_PER_SIDE then
        side = side + 1
        if side > #SIDES then
            side = 1
            laps = laps + 1
            say(string.format("lap %d done at (%d,%d) -- peak bikeSpeed so far = %d",
                laps, x, y, peak))
        end
        sideStartX, sideStartY = x, y
        return -- release for one frame at the corner, so the turn is a turn and not a smear
    end

    joypad.set({ [s.key] = true })
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) say("unloaded, keys released") end
else
    while true do tick() emu.frameadvance() end
end
