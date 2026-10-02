-- MeshGhost — Emerald: is gMain.oamBuffer[64..127] dead space the engine never writes? (dev tool, read-only)
-- Walk a busy map, open the START menu and a text box, enter a battle: ResetOamRange is the one legitimate clear.
local GMAIN_ADDR = 0x030022c0
local OAMBUF_ADDR = GMAIN_ADDR + 0x038
local GOAMLIMIT_ADDR = 0x02021b38
local OAM_ADDR = 0x07000000
local OAM_ENTRIES = 128
local ENTRY_SIZE = 8
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

-- gDummyOamData, the engine's own hidden entry.
local DUMMY_A0, DUMMY_A1, DUMMY_A2 = 0x00a0, 0x0130, 0x0c00

local REPORT_FRAMES = 60

local function scriptDir()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end

local logfile = io.open(scriptDir() .. "/oamshadow_probe.log", "w")
local function log(msg)
    console.log(msg)
    if logfile then logfile:write(msg, "\n") logfile:flush() end
end

local function r16(a) return memory.read_u16_le(a) end

-- The +1 is the Thumb bit: callback2 holds the Thumb form, and a test of the even address alone never matches.
local function inOverworld()
    local cb2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    return cb2 == CB2_OVERWORLD_ADDR or cb2 == CB2_OVERWORLD_ADDR + 1
end

-- Last frame's entries above the limit: +0/+2/+4 are the halfwords the tier wants to own, +6 is the engine's.
local prev = {}
local frame = 0

-- Running verdicts: each starts as the claim being true and can only be falsified.
local limitSeen = {}
local attrChanged = 0        -- frames on which +0/+2/+4 moved in 64..127
local attrChangedWhere = nil -- the first index that did it, kept for the log
local affineChanged = 0      -- frames on which +6 moved there (expected to be most of them)
-- Counted apart below and above the limit, and neither settles claim 2 (LoadOam pushes all 128): above it both sides
-- are dummy, and below it the engine has already rebuilt the shadow for the coming frame while hardware holds the last
-- VBlank's copy. oaminject_probe.lua settles it by drawing.
local hwMismatch = 0         -- frames on which shadow and hardware disagreed above the limit
local hwMismatchBelow = 0    -- ... and below it -- PHASE, not a failure: see the verdict text
local hwMismatchWhere = nil
local occupiedAboveMax = 0   -- high-water mark of non-dummy entries above the limit
local framesCounted = 0

local function tick()
    frame = frame + 1
    if not inOverworld() then return end
    framesCounted = framesCounted + 1

    local limit = memory.read_u8(GOAMLIMIT_ADDR)
    limitSeen[limit] = (limitSeen[limit] or 0) + 1

    local belowUsed, aboveUsed = 0, 0
    local changedAttr, changedAffine, mismatch, mismatchBelow = false, false, false, false

    for i = 0, OAM_ENTRIES - 1 do
        local s = OAMBUF_ADDR + i * ENTRY_SIZE
        local a0, a1, a2 = r16(s), r16(s + 2), r16(s + 4)
        local isDummy = (a0 == DUMMY_A0 and a1 == DUMMY_A1 and a2 == DUMMY_A2)
        if i < limit then
            if not isDummy then belowUsed = belowUsed + 1 end
            local h = OAM_ADDR + i * ENTRY_SIZE
            if r16(h) ~= a0 or r16(h + 2) ~= a1 or r16(h + 4) ~= a2 then
                mismatchBelow = true
            end
        else
            if not isDummy then aboveUsed = aboveUsed + 1 end

            -- Claim 1: nothing in the per-frame path writes attributes up here.
            local p = prev[i]
            local a3 = r16(s + 6)
            if p then
                if p[1] ~= a0 or p[2] ~= a1 or p[3] ~= a2 then
                    changedAttr = true
                    attrChangedWhere = attrChangedWhere or
                        string.format("i=%d %04x/%04x/%04x -> %04x/%04x/%04x",
                            i, p[1], p[2], p[3], a0, a1, a2)
                end
                if p[4] ~= a3 then changedAffine = true end
            end
            prev[i] = { a0, a1, a2, a3 }

            -- Claim 2: LoadOam pushed all 128, so hardware agrees with the shadow up here.
            local h = OAM_ADDR + i * ENTRY_SIZE
            local h0, h1, h2 = r16(h), r16(h + 2), r16(h + 4)
            if h0 ~= a0 or h1 ~= a1 or h2 ~= a2 then
                mismatch = true
                hwMismatchWhere = hwMismatchWhere or
                    string.format("i=%d shadow %04x/%04x/%04x hw %04x/%04x/%04x",
                        i, a0, a1, a2, h0, h1, h2)
            end
        end
    end

    if changedAttr then attrChanged = attrChanged + 1 end
    if changedAffine then affineChanged = affineChanged + 1 end
    if mismatch then hwMismatch = hwMismatch + 1 end
    if mismatchBelow then hwMismatchBelow = hwMismatchBelow + 1 end
    if aboveUsed > occupiedAboveMax then occupiedAboveMax = aboveUsed end

    if framesCounted % REPORT_FRAMES == 0 then
        log(string.format("frame=%d limit=%d used<limit=%d used>=limit=%d (max %d) "
            .. "attrMoved=%d affineMoved=%d hwMismatch=%d/%d(below)",
            frame, limit, belowUsed, aboveUsed, occupiedAboveMax,
            attrChanged, affineChanged, hwMismatch, hwMismatchBelow))
    end
end

log("=== oamshadow_probe: read-only, measuring the three claims the hardware tier rests on ===")
log(string.format("shadow buffer at 0x%08x, entry 64 at 0x%08x", OAMBUF_ADDR, OAMBUF_ADDR + 64 * 8))

MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function()
    local limits = {}
    for k, v in pairs(limitSeen) do limits[#limits + 1] = string.format("%d(x%d)", k, v) end
    table.sort(limits)
    log("=== done ===")
    log(string.format("overworld frames measured: %d", framesCounted))
    log(string.format("gOamLimit values seen: %s", table.concat(limits, " ")))
    log(string.format("CLAIM 1 (engine never writes attrs at/above the limit): %s -- %d frames moved%s",
        attrChanged == 0 and "HOLDS" or "FAILED", attrChanged,
        attrChangedWhere and (", first " .. attrChangedWhere) or ""))
    log(string.format("CLAIM 2 (LoadOam pushes all 128): %s above the limit -- %d frames disagreed "
        .. "there%s. Below the limit %d frames differed, which is one frame of PHASE (shadow already "
        .. "rebuilt, hardware still holding the last VBlank copy), not evidence either way. "
        .. "DECIDED BY STAGE 1, not by this probe.",
        hwMismatch == 0 and "CONSISTENT" or "FAILED", hwMismatch,
        hwMismatchWhere and (", first " .. hwMismatchWhere) or "", hwMismatchBelow))
    log(string.format("CLAIM 3 (+6 IS rewritten every frame): %s -- %d frames moved",
        affineChanged > 0 and "HOLDS" or "NOT SEEN", affineChanged))
    log(string.format("high-water non-dummy entries at/above the limit: %d "
        .. "(anything but 0 means something else already lives in our window)", occupiedAboveMax))
    if logfile then logfile:close() logfile = nil end
end

if not MESHGHOST_DEV_LOADER then
    while true do
        tick()
        emu.frameadvance()
    end
end
