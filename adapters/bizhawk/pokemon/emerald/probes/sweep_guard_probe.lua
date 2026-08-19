-- MeshGhost — Emerald: does the orphan sweep's predicate ever fire where it should not?
-- READ-ONLY. Writes nothing to the game; a log file beside itself is its only output.
--
-- WHY
-- meshghost_emerald.lua's sweepOrphanGhosts() clears any object event that is "active, not the
-- player, localId == LOCALID_PLAYER", because only our own spawned ghosts can be in that state.
-- Until 2026-08-19 it ran unconditionally, once every 60 frames -- including before the object
-- array had been located (avatarAddrConfirmed false), outside the overworld, and on an
-- Archipelago-patched ROM where that same function would have read a RELOCATED gObjectEvents and
-- then written the VANILLA gSprites. That last combination is exactly the unmeasured write the
-- adapter's render-path split exists to avoid (BANDAGES.md).
--
-- The gate is cheap and obviously right, but "obviously right" is not a measurement. This probe
-- answers the question the gate is a fix for: OUTSIDE the overworld, and before detection
-- succeeds, does anything in the object array actually satisfy that predicate? If it never does,
-- the gate is defensive and should be described that way; if it does, the old code was writing
-- into live memory that had nothing to do with us.
--
-- WHAT IT REPORTS
--   * inOverworld(), from gMain.callback2, exactly as the adapter computes it;
--   * whether the player's own object event is findable at the vanilla base and at the
--     Archipelago-shifted one (the adapter's own detection predicate);
--   * per frame, how many of the 16 slots at the vanilla base match the sweep's predicate, with
--     the raw bytes of each match -- so a hit can be told from a coincidence.
-- A line is written whenever the count is non-zero or any of the three flags changes, plus a
-- heartbeat every 300 frames so a quiet run is distinguishable from a dead one.
--
-- HOW TO RUN
--   Point dev-scripts/bizhawk-dev-loader.target at this file. Sit at the title screen / the
--   continue screen for a while, then load a save and walk around; the interesting window is the
--   one BEFORE the overworld.

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local CB2_OVERWORLD_ARCHIPELAGO_ADDR = 0x080867f1
local GOBJECTEVENTS_ADDR = 0x02037350
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
local OBJECTEVENT_SIZE = 0x24
local MAP_GROUPS_COUNT = 34
local GHOST_LOCAL_ID = 255
-- All of the above are the adapter's own constants, copied so this probe measures the same thing
-- the adapter does rather than a re-derivation of it.

local function scriptDir()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end

local logfile = io.open(scriptDir() .. "/sweep_guard_probe.log", "w")
local function log(msg)
    console.log(msg)
    if logfile then logfile:write(msg, "\n") logfile:flush() end
end

local function r8(a) return memory.read_u8(a) end

local function inOverworld()
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    return cb == CB2_OVERWORLD_ADDR or cb == CB2_OVERWORLD_ADDR + 1
        or cb == CB2_OVERWORLD_ARCHIPELAGO_ADDR or cb == CB2_OVERWORLD_ARCHIPELAGO_ADDR + 1
end

local function playerObjEventExistsAt(base)
    for i = 0, 15 do
        local a = base + i * OBJECTEVENT_SIZE
        if (r8(a + 0x02) & 1) == 1 and r8(a + 0x08) == 0xff and r8(a + 0x0a) < MAP_GROUPS_COUNT then
            return true
        end
    end
    return false
end

-- sweepOrphanGhosts()'s predicate, verbatim, with the "we are tracking it" half removed: this
-- probe has no ghosts of its own, so every match here is something the sweep would have cleared.
local function sweepMatches(base)
    local hits = {}
    for i = 0, 15 do
        local a = base + i * OBJECTEVENT_SIZE
        if (r8(a + 0x00) & 1) == 1 and (r8(a + 0x02) & 1) == 0 and r8(a + 0x08) == GHOST_LOCAL_ID then
            hits[#hits + 1] = string.format("slot %d {flags=%02X %02X localId=%02X spriteId=%d "
                .. "gfx=%d mapNum=%d mapGroup=%d}", i, r8(a + 0x00), r8(a + 0x02), r8(a + 0x08),
                r8(a + 0x04), r8(a + 0x05), r8(a + 0x09), r8(a + 0x0a))
        end
    end
    return hits
end

local frame = 0
local lastKey = nil
local totalHitFrames, totalHitFramesOutside = 0, 0

local function tick()
    frame = frame + 1
    local ow = inOverworld()
    local vanilla = playerObjEventExistsAt(GOBJECTEVENTS_ADDR)
    local ap = playerObjEventExistsAt(GOBJECTEVENTS_ADDR + AVATAR_ADDR_ARCHIPELAGO_SHIFT)
    local hits = sweepMatches(GOBJECTEVENTS_ADDR)

    if #hits > 0 then
        totalHitFrames = totalHitFrames + 1
        if not ow then totalHitFramesOutside = totalHitFramesOutside + 1 end
    end

    local key = string.format("%s|%s|%s|%d", tostring(ow), tostring(vanilla), tostring(ap), #hits)
    if key ~= lastKey then
        lastKey = key
        log(string.format("frame=%d overworld=%s playerObjAt(vanilla)=%s playerObjAt(AP)=%s "
            .. "sweepWouldClear=%d %s", frame, tostring(ow), tostring(vanilla), tostring(ap),
            #hits, table.concat(hits, " ")))
    end

    if frame % 300 == 0 then
        log(string.format("heartbeat frame=%d overworld=%s hitFrames=%d hitFramesOutsideOverworld=%d",
            frame, tostring(ow), totalHitFrames, totalHitFramesOutside))
    end
end

log("=== sweep_guard_probe: read-only, measuring the orphan sweep's predicate ===")

MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function()
    log(string.format("=== done: %d frames, %d with a match, %d of those outside the overworld ===",
        frame, totalHitFrames, totalHitFramesOutside))
    if logfile then logfile:close() logfile = nil end
end

if not MESHGHOST_DEV_LOADER then
    while true do
        tick()
        emu.frameadvance()
    end
end
