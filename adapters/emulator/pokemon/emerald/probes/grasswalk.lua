-- MeshGhost — Emerald: 3 tiles up and 3 down forever, counted in the player's own coordinates, never frames (dev tool).
-- It stops for good outside the overworld (in a battle a direction moves the cursor), under a script, or when blocked.

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

-- A one-shot lead-in rather than a longer route, so the repeating part stays the same length.
local LEAD_IN_DOWN = 4
local TILES_PER_SIDE = 3
local SIDES = {
    { key = "Up",   axis = "y", delta = -1 },
    { key = "Down", axis = "y", delta =  1 },
}

-- Far past a walking step, so only a real block (a wall, a character, a ledge) trips it.
local STUCK_FRAMES = 100

local side, sideStartX, sideStartY = 1, nil, nil
local stuckFor, lastX, lastY = 0, nil, nil
local laps, peak, stopped = 0, 0, false
local leadFrom = nil

local function say(s) console.log("grasswalk: " .. s) end
local function r8(a) return memory.read_u8(a) end

local function controllable()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1 then
        return false, "not the overworld"
    end
    -- preventStep is set while a script owns the player (a trainer's approach, a sign, a warp); callback2 stays put.
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
        leadFrom = y
        say(string.format("moving %d tiles down first, from (%d,%d)", LEAD_IN_DOWN, x, y))
    end

    if leadFrom and (y - leadFrom) < LEAD_IN_DOWN then
        joypad.set({ Down = true })
        return
    elseif leadFrom then
        leadFrom = nil
        sideStartX, sideStartY, lastX, lastY, stuckFor = x, y, x, y, 0
        say(string.format("walking from (%d,%d): 3 up, 3 down, repeating", x, y))
    end

    local speed = r8(GPLAYERAVATAR_ADDR + 0x0b)
    if speed > peak then peak = speed end

    -- Blocked: grinding into a wall for the rest of the session teaches nothing, so say where and stop.
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
            say(string.format("lap %d done at (%d,%d) -- walking y %d..%d",
                laps, x, y, y - TILES_PER_SIDE, y))
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
