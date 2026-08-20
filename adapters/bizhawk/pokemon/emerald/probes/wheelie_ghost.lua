-- MeshGhost -- why does a GHOST not finish a wheelie, when the player does? (DEV TOOL, never shipped)
--
-- WHY. `wheelie_watch.lua` settled the half of this that was theory: driven on the player, every
-- Acro Bike wheelie action completes -- 0x6B, one of the three the adapter's watchdog kept freeing
-- at its 60-frame limit, ran nine frames and reported finished (`agent_docs/verified.md`,
-- 2026-08-20). So the action is completable and the difference is in the ghost. This measures the
-- ghost's own fields through the same action, which is the comparison that was never made.
--
-- WHAT THE PLAYER LOOKED LIKE, to compare against: nine frames with `data2` (the step function's
-- sub-state) at 1 and the sprite's paused bit CLEAR, its animation number 23 and its command index
-- advancing 0 -> 1, then `data2` = 2 and finished on the tenth frame. A sub-state that never leaves
-- 1 is therefore a step function still waiting for its animation.
--
-- THREE CONDITIONS, not one, and the third is the combination -- "A alone did nothing" never
-- implies A+B does nothing (`CLAUDE.md`):
--   1. the action as the adapter issues it today
--   2. plus the engine's own `enableAnim` switch on the object (byte +0x01, bit 0x08), which is
--      what clears a paused sprite the way the game does
--   3. plus clearing the sprite's paused bit outright, every frame
-- A ghost's sprite is known to sit PAUSED most of the time it is settled (`verified.md`: paused on
-- 232 of 252 stepping frames before that was fixed), which is why pausing is the first suspect.
--
-- The adapter is left running underneath: it issues no new step while a ghost reads busy, so an
-- action written here runs undisturbed until it finishes or its watchdog frees it. Both outcomes
-- are visible in this log.
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE = 0x24
local SPRITE_SIZE = 0x44
local GHOST_LOCAL_ID = 255
local ACRO_BIKE_GFX = { [63] = true, [91] = true }   -- Brendan / May, verified.md's graphicsId table
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

-- The fourth condition is the one that matters now: conditions 1-3 all FINISHED in eleven
-- frames, so a ghost on the Acro Bike completes the pop-wheelie perfectly well and pausing was
-- never the cause. What is left is the ghost NOT wearing the bike when the action arrives --
-- the peer's graphic and its action travel separately -- so the same action is issued again
-- with the ghost on the walking graphic. A hang there is the whole explanation.
-- ROUND TWO. The first three conditions above all FINISHED in eleven frames, so a ghost sitting
-- idle on the Acro Bike completes the pop-wheelie perfectly, and neither pausing nor `enableAnim`
-- was ever the cause. What is different in the adapter is WHEN it issues these: the wheelie branch
-- fires on the peer's action CHANGING and does not check `ghostIsIdle` first, so the action lands
-- on top of a step that is still running. `requestAction` resets the sprite's `data[2]`
-- (`sActionFuncId`) but leaves `data[1]` (`sTypeFuncId`) alone -- and `data[1]` is what selects
-- which FAMILY of step functions the engine calls. Stale, it keeps calling the old family with the
-- new action id, which is a step that can never report finished.
-- ROUND THREE, after round two also finished in eleven frames: `data[1]` was already 0 in the
-- interrupted case, so a stale step-function family is not it either.
--
-- What every attempt so far shares is that the action's DIRECTION matched the ghost's own facing,
-- because the probe derived one from the other. The adapter does not: it mirrors the PEER's action
-- id verbatim, and the direction baked into that id is the peer's facing, which the ghost need not
-- have yet. The three ids the watchdog kept freeing were 0x69, 0x6B and 0x6D -- never the `+0`
-- south member, which is the one a probe facing south would produce. So: issue all four members of
-- the family to a ghost, whatever way it happens to be facing, and see which of them hang.
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

    -- A condition that wants the action to land mid-step has to WAIT for a real step: the adapter
    -- drives the ghost from the peer, so the honest way to reach that state is to let it happen
    -- rather than to fake a movement here.
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
        line(string.format("# condition %d %s (interrupting action %02X, data1=%d)",
            ci, CONDS[ci].name, r8(a + 0x1c), memory.read_s16_le(s + 0x30)))
        -- Issued exactly the way the adapter does: action id, heldMovementActive set and finished
        -- cleared, and the step function's sub-state reset.
        w8(a + 0x1c, ACTION + (r8(a + 0x18) & 0x0f) - 1)
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
