-- MeshGhost -- catch a ghost hopping when the player is not (DEV TOOL, never shipped)
--
-- WHY. User, 2026-08-20: the ghosts hop while riding the Acro Bike normally left/right, which is
-- not what the player is doing. A driven three-tile shuttle (probes/acroride.lua) produced none of
-- it -- the player reported only RIDE_WATER_CURRENT (0x2B/0x2C) and both objects stayed flat on the
-- ground -- so whatever produces the hop is in how the bike is really ridden, not in riding as
-- such. This is the passive half: it drives nothing and waits for the real thing to happen.
--
-- WHAT COUNTS AS A HOP, as a number rather than an impression: the sprite's pos2 y is the vertical
-- offset the jump/hop step functions write, so a ghost off the ground has pos2 y < 0. The line
-- carries the PLAYER's own pos2 y on the same frame, which is what makes it a disagreement rather
-- than an observation -- a hop both of them do is the peer's, a hop only the ghost does is ours.
--
-- It logs the frame a hop STARTS and the frame it ends, not every frame in between: a per-frame
-- write with the game running is a probe heavy enough to change what it measures (pitfalls.md,
-- 2026-08-16), and the interesting facts are the action ids at the two edges.
--
-- Addresses copied from meshghost_emerald.lua, never from memory.
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE = 0x24
local SPRITE_SIZE = 0x44
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local GHOST_LOCAL_ID = 255

local function r8(a) return memory.read_u8(a) end
local function rs16(a) return memory.read_s16_le(a) end

local BSLASH = string.char(92)
local logPath = ("%s/hopwatch_%s.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."),
    os.date("%Y%m%d_%H%M%S"))
local logFile = io.open(logPath, "a")
local function say(s)
    console.log("hopwatch: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end
local function line(s) if logFile then logFile:write(s .. string.char(10)) logFile:flush() end end

local function playerObj()
    return GOBJECTEVENTS_ADDR + r8(GPLAYERAVATAR_ADDR + 0x05) * OBJECTEVENT_SIZE
end

-- Every ghost, not the first: a COMPARE_TIERS session has one spawned ghost, but a room can carry
-- several and the one that hops is the one worth naming.
local function ghosts()
    local out = {}
    for i = 0, 15 do
        local a = GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE
        if (r8(a) & 0x01) == 1 and (r8(a + 0x02) & 0x01) == 0 and r8(a + 0x08) == GHOST_LOCAL_ID then
            out[#out + 1] = { id = i, addr = a }
        end
    end
    return out
end

local frame, airborne, hops = 0, {}, 0
local lastPlayerX, playerStepSign = nil, nil
-- The second half, added after the first run answered its own question: every ghost hop in that
-- capture was a hop the PLAYER had just done, so nothing invents hops. What the user saw next is
-- narrower (2026-08-20): *"when i was going right, the spawned ghost was still facing left, and
-- hopping backwards"*, and *"the drawn ghost was fine, only the spawned one"*. Same data in, one
-- tier wrong, so this measures the spawned object's own facing against the player's -- edge
-- triggered, so a disagreement costs two lines and its LENGTH is the number that matters. A few
-- frames is the interpolation delay; a second is a defect.
local facingSince, backwardSince = {}, {}

local function describe(a)
    local s = GSPRITES_ADDR + r8(a + 0x04) * SPRITE_SIZE
    return string.format("act=%02X gfx=%d dir=%02X pos2=%d,%d anim=%d/%d xy=%d,%d",
        r8(a + 0x1c), r8(a + 0x05), r8(a + 0x18), rs16(s + 0x24), rs16(s + 0x26),
        r8(s + 0x2a), r8(s + 0x2b), rs16(a + 0x10), rs16(a + 0x12)), rs16(s + 0x26)
end

local function tick()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1 then return end
    frame = frame + 1

    local p = playerObj()
    local pDesc, pY = describe(p)
    local pFace = r8(p + 0x18) & 0x0f
    local pX = rs16(p + 0x10)
    -- The player's own last direction of travel, remembered across tiles: "backwards" only means
    -- anything relative to the way the peer is actually going.
    if lastPlayerX and pX ~= lastPlayerX then playerStepSign = pX > lastPlayerX and 1 or -1 end
    lastPlayerX = pX

    for _, g in ipairs(ghosts()) do
        local gDesc, gY = describe(g.addr)
        local gFace = r8(g.addr + 0x18) & 0x0f
        local gX = rs16(g.addr + 0x10)

        -- FACING: two lines per disagreement, carrying how long it lasted.
        if gFace ~= pFace then
            facingSince[g.id] = facingSince[g.id] or frame
        elseif facingSince[g.id] then
            local held = frame - facingSince[g.id]
            if held >= 8 then
                line(string.format("f=%d FACING disagreed for %d frames, ghost%d now agrees | ghost %s | player %s",
                    frame, held, g.id, gDesc, pDesc))
                say(string.format("ghost%d faced the wrong way for %d frames", g.id, held))
            end
            facingSince[g.id] = nil
        end

        -- BACKWARDS: a ghost tile step whose direction is the opposite of the way the peer last went.
        local lastX = backwardSince[g.id]
        if lastX and gX ~= lastX then
            local sign = gX > lastX and 1 or -1
            if playerStepSign and sign ~= playerStepSign then
                line(string.format("f=%d BACKWARD STEP ghost%d went %s while the player is going %s | ghost %s | player %s",
                    frame, g.id, sign == 1 and "east" or "west",
                    playerStepSign == 1 and "east" or "west", gDesc, pDesc))
                say(string.format("ghost%d stepped BACKWARDS at frame %d", g.id, frame))
            end
        end
        backwardSince[g.id] = gX
        local up = gY < 0
        if up and not airborne[g.id] then
            airborne[g.id] = frame
            hops = hops + 1
            line(string.format("f=%d HOP START ghost%d %s | player %s%s",
                frame, g.id, gDesc, pDesc, pY < 0 and "  (THE PLAYER IS OFF THE GROUND TOO)" or
                "  <-- the player is on the ground"))
            if hops <= 3 or hops % 10 == 0 then
                say(string.format("hop %d: ghost%d off the ground, player %s",
                    hops, g.id, pY < 0 and "also hopping" or "NOT hopping"))
            end
        elseif not up and airborne[g.id] then
            line(string.format("f=%d hop end   ghost%d after %d frames %s | player %s",
                frame, g.id, frame - airborne[g.id], gDesc, pDesc))
            airborne[g.id] = nil
        end
    end
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
