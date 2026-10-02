-- MeshGhost — Pokémon Emerald: catch a ghost hopping when the player is not (dev tool, read-only, never shipped).
-- Per ghost it logs the frame a hop starts and ends (its sprite's pos2 y below 0) beside the player's own pos2 y, a
-- facing disagreement and a tile step against the player's last direction: a hop only the ghost does is ours. Edges
-- only, so a disagreement's length is the number: a few frames is the interpolation delay, a second is a defect.
-- Addresses as in meshghost_emerald.lua.
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
    -- Kept across tiles: "backwards" only means anything against the way the player last went.
    if lastPlayerX and pX ~= lastPlayerX then playerStepSign = pX > lastPlayerX and 1 or -1 end
    lastPlayerX = pX

    for _, g in ipairs(ghosts()) do
        local gDesc, gY = describe(g.addr)
        local gFace = r8(g.addr + 0x18) & 0x0f
        local gX = rs16(g.addr + 0x10)

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
