-- MeshGhost — Emerald: is gMain.oamBuffer[64..127] really dead space, and does it reach hardware?
-- READ-ONLY. Writes nothing to the game; a log file beside itself is its only output.
--
-- WHY
-- The hardware-sprite tier (plans.md Phase 8.1) rests on three claims taken from the decomp and the
-- build map rather than from a running game (verified.md 2026-08-21):
--
--   1. gOamLimit is 64 on the overworld, so the engine's per-frame dummy-fill stops there and
--      indices 64..127 of the shadow buffer are never written by the sprite system;
--   2. LoadOam copies the FULL 128 entries to hardware OAM every VBlank regardless of that limit,
--      so anything parked above the limit is displayed for free on the game's own DMA;
--   3. the only thing rewritten on all 128 entries every frame is affineParam at byte +6
--      (CopyMatricesToOamBuffer), so a tier that writes +0/+2/+4 and never +6 is not fighting it.
--
-- Every later stage writes into that window. A wrong address there is not a crash -- it is a
-- plausible number and a corrupted sprite somewhere else -- so this probe exists to turn all three
-- claims into observations before a single byte is written. It is the cheap de-risk: nothing
-- appears on screen, and nothing can be broken by running it.
--
-- WHAT IT REPORTS, once a second and again at unload
--   * gOamLimit's live value, and whether it ever moves (the slot machine raises it to 0x80);
--   * how many of the 128 shadow entries are non-dummy, split at the limit -- the count below it is
--     the engine's own sprite list, the count above it should be a flat zero;
--   * whether any of bytes +0/+2/+4 in 64..127 EVER differ between two consecutive frames, and at
--     which index if so. That is claim 1, stated as something that can fail;
--   * whether +6 differs between frames in the same range -- claim 3, which SHOULD change;
--   * a byte-compare of shadow 64..127 against hardware OAM 0x07000000 + 512..1023. Claim 2 holds
--     only if they agree; if they diverge, the transfer is bounded after all and the whole design
--     moves to a different injection point.
--
-- READ AT A FRAME BOUNDARY, deliberately. The comparison in claim 2 is "does what the engine built
-- last frame match what the hardware is holding now", which is exactly what a between-frames read
-- sees. A mid-frame hook would be answering a different question.
--
-- HOW TO RUN
--   Point dev-scripts/bizhawk-dev-loader.target at this file, load a save, and walk around a busy
--   map for a minute -- a map with several NPCs is the interesting one, because that is when the
--   engine's own list is long enough for a boundary mistake to show. Then open the START menu and a
--   text box, and step into a battle and back out if you can reach one, since ResetOamRange(0,128)
--   at a scene change is the one thing that legitimately does clear our window.

-- Addresses: gMain from our own make-compare-verified pokeemerald build (agent_docs/environment.md);
-- the oamBuffer offset of 0x038 derived from struct Main's field list and cross-checked two ways
-- (verified.md 2026-08-21). OAM_ADDR and the 8-byte stride are GBA hardware, not facts about Emerald.
local GMAIN_ADDR = 0x030022c0
local OAMBUF_ADDR = GMAIN_ADDR + 0x038
local GOAMLIMIT_ADDR = 0x02021b38
local OAM_ADDR = 0x07000000
local OAM_ENTRIES = 128
local ENTRY_SIZE = 8
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

-- The engine's own "hidden" encoding, gDummyOamData: y=160, x=304, 8x8, priority 3.
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

-- The +1 is the Thumb bit: gMain.callback2 holds a function POINTER, and the engine stores the
-- Thumb-mode form. Measured live 2026-08-21 as 0x08085e5d, and the adapter tests both forms for the
-- same reason (meshghost_emerald.lua:136). A probe that only tested the even address would sit
-- silent forever and look like a dead emulator.
local function inOverworld()
    local cb2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    return cb2 == CB2_OVERWORLD_ADDR or cb2 == CB2_OVERWORLD_ADDR + 1
end

-- Last frame's entries above the limit, so "did anything change" is a real comparison rather than a
-- guess. Four halfwords per entry: +0/+2/+4 are the ones the tier wants to own, +6 is the engine's.
local prev = {}
local frame = 0

-- Running verdicts. Each starts out as the claim being true and can only ever be falsified -- a
-- probe that can only confirm what it went looking for is worth nothing.
local limitSeen = {}
local attrChanged = 0        -- frames on which +0/+2/+4 moved in 64..127
local attrChangedWhere = nil -- the first index that did it, kept for the log
local affineChanged = 0      -- frames on which +6 moved there (expected to be most of them)
-- Hardware-vs-shadow is counted SEPARATELY below and above the limit, and NEITHER half settles
-- claim 2 on its own -- learned by running it, 2026-08-21. Above the limit both sides are dummy on
-- a clean run, so agreement is trivially true. Below it the two legitimately disagree on some
-- frames: this probe reads at a frame boundary, where the engine has already rebuilt the shadow for
-- the coming frame while hardware still holds the copy LoadOam made at the last VBlank. That is one
-- frame of phase, not a bounded transfer, and it showed up on ~6% of frames (134 of 2250) exactly
-- when sprites were moving. So the below-limit number is reported as PHASE, and claim 2 is settled
-- properly only by Stage 1: park something non-dummy above the limit and see whether it appears.
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
