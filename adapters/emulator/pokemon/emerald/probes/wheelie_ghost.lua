-- MeshGhost — why a ghost does not finish a wheelie when the player does (dev tool, writes live RAM: a ghost's
-- movement action, vanilla only, never shipped). Issues each condition in CONDS to a ghost on the Acro Bike and logs
-- its object and sprite fields for 120 frames, noting when it finishes. Run it with the adapter loaded: that issues no
-- new step while the ghost is busy, so the action runs until it finishes or the adapter's watchdog frees it.
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE = 0x24
local SPRITE_SIZE = 0x44
local GHOST_LOCAL_ID = 255
local ACRO_BIKE_GFX = { [63] = true, [91] = true }   -- Brendan / May
local ACTION = 0x68                                   -- ACRO_POP_WHEELIE_*, family base

local function r8(a) return memory.read_u8(a) end
local function w8(a, v) memory.write_u8(a, v) end
local function w16(a, v) memory.write_u16_le(a, v) end

local BSLASH = string.char(92)
local logPath = ("%s/wheelie_ghost_%s.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."),
    os.date("%Y%m%d_%H%M%S"))
local logFile = io.open(logPath, "a")
local function say(s)
    console.log("wheelie_ghost: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end
local function line(s) if logFile then logFile:write(s .. string.char(10)) logFile:flush() end end

local function findGhost()
    for i = 0, 15 do
        local a = GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE
        if (r8(a) & 0x01) == 1 and (r8(a + 0x02) & 0x01) == 0 and r8(a + 0x08) == GHOST_LOCAL_ID then
            return i
        end
    end
    return nil
end

local CONDS = {
    { name = "pop wheelie, direction matching the ghost's own facing", frames = 120 },
    { name = "pop wheelie SOUTH (0x68) regardless of facing", frames = 120, act = 0x68 },
    { name = "pop wheelie NORTH (0x69) regardless of facing", frames = 120, act = 0x69 },
    { name = "pop wheelie WEST  (0x6A) regardless of facing", frames = 120, act = 0x6a },
    { name = "pop wheelie EAST  (0x6B) regardless of facing", frames = 120, act = 0x6b },
    { name = "end wheelie NORTH (0x6D) regardless of facing", frames = 120, act = 0x6d },
}

local n, ci, waited, issued = 0, 1, nil, false

local function tick()
    if ci > #CONDS then return end
    local objId = findGhost()
    if not objId then
        if waited ~= "noghost" then waited = "noghost" say("waiting for a ghost to exist") end
        return
    end
    local a = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
    local gfx = r8(a + 0x05)
    local wantBike = CONDS[ci].wantBike ~= false
    local onBike = ACRO_BIKE_GFX[gfx] == true
    if onBike ~= wantBike then
        if waited ~= gfx then
            waited = gfx
            say(string.format("waiting for the ghost to be %s (graphicsId %d)",
                wantBike and "on the Acro Bike" or "OFF the bike", gfx))
        end
        return
    end
    if waited then waited = nil say("ghost in slot " .. objId .. " ready (graphicsId " .. gfx .. ") -- measuring") end

    local s = GSPRITES_ADDR + r8(a + 0x04) * SPRITE_SIZE

    -- An overStep condition waits for a real step from the peer rather than faking one.
    if n == 0 and CONDS[ci].overStep then
        local busy = (r8(a) & 0xc0) == 0x40 and r8(a + 0x1c) ~= 0xff
        if not busy then
            if waited ~= "step" then waited = "step" say("waiting for the ghost to be mid-step -- move the player") end
            return
        end
        waited = nil
    end

    n = n + 1

    if n == 1 then
        say(string.format("condition %d/%d: %s", ci, #CONDS, CONDS[ci].name))
        -- The id actually written goes in the header line, so each condition is proved different.
        local want = CONDS[ci].act or (ACTION + (r8(a + 0x18) & 0x0f) - 1)
        line(string.format("# condition %d %s (issuing %02X, ghost facing %02X, interrupting action %02X, data1=%d)",
            ci, CONDS[ci].name, want, r8(a + 0x18), r8(a + 0x1c), memory.read_s16_le(s + 0x30)))
        -- Issued the way the adapter does: action id, heldMovementActive set, finished cleared, sub-state reset.
        w8(a + 0x1c, want)
        w8(a + 0x00, (r8(a) | 0x40) & ~0x80)
        w16(s + 0x32, 0)
        if CONDS[ci].clearType then w16(s + 0x30, 0) end
        issued = true
    end

    local b0 = r8(a)
    line(string.format(
        "n=%3d cond=%d act=%02X active=%d finished=%d dir=%02X b1=%02X anim=%d/%d paused=%d "
        .. "data1=%d data2=%d gfx=%d",
        n, ci, r8(a + 0x1c), (b0 >> 6) & 1, (b0 >> 7) & 1, r8(a + 0x18), r8(a + 0x01),
        r8(s + 0x2a), r8(s + 0x2b), (r8(s + 0x2c) >> 6) & 1,
        memory.read_s16_le(s + 0x30), memory.read_s16_le(s + 0x32), gfx))

    if issued and (b0 >> 7) & 1 == 1 then
        say(string.format("condition %d FINISHED after %d frames", ci, n))
        issued = false
    end
    if n >= CONDS[ci].frames then
        if issued then say(string.format("condition %d never finished in %d frames", ci, n)) end
        ci, n, issued = ci + 1, 0, false
        if ci > #CONDS then say("done -- " .. logPath) end
    end
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
