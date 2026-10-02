-- MeshGhost — Emerald: does the orphan sweep's predicate ever match outside the overworld? (dev tool, read-only)
-- Sit at the title or continue screen, then load a save and walk; the window before the overworld is the question.

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local CB2_OVERWORLD_ARCHIPELAGO_ADDR = 0x080867f1
local GOBJECTEVENTS_ADDR = 0x02037350
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
local OBJECTEVENT_SIZE = 0x24
local MAP_GROUPS_COUNT = 34
local GHOST_LOCAL_ID = 255
-- The adapter's own constants, copied so this measures what the adapter does rather than a re-derivation.

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

-- The sweep's predicate without its tracked-ghost half: with no ghosts of its own, every match is one it would clear.
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
