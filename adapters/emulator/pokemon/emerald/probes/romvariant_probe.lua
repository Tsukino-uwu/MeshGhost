-- MeshGhost — Emerald: identify an Emerald-derived ROM and resolve its anchors by search (dev tool, read-only).
-- Each is RESOLVED, AMBIGUOUS (all printed) or UNRESOLVED, never picked; be in the overworld for the live phase.

-- The backslash is built: this emulator's Lua rejects the escaped form.

local BS = string.char(92)
local scriptDir = (debug.getinfo(1, "S").source:sub(2)
    :match("^(.*)[/" .. BS .. "][^/" .. BS .. "]*$") or ".")
local logPath = scriptDir .. "/romvariant_probe_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
local fh = io.open(logPath, "w")

local function say(line)
    if fh then fh:write(line .. "\n") fh:flush() end
end

local function loud(line)
    console.log("romvariant: " .. line)
    say(line)
end

console.log("romvariant: writing " .. logPath)

if not memory.usememorydomain("System Bus") then
    loud("ERROR: 'System Bus' memory domain not found on this core -- nothing measured.")
    return
end

local function r8(a) return memory.read_u8(a) end
local function r16(a) return memory.read_u16_le(a) end
local function r32(a) return memory.read_u32_le(a) end
local function rs16(a) return memory.read_s16_le(a) end
local function hex(v) return string.format("0x%08X", v) end
local function isRomPtr(p) return p >= 0x08000000 and p <= 0x09ffffff end

-- Vanilla addresses: labels, never inputs to a search.

local V = {
    romBase                = 0x08000000,
    palBrendan             = 0x084987f8,
    palMay                 = 0x084a4278,
    picBrendanNormal       = 0x084975f8,
    picBrendanRunning      = 0x08497ef8,
    gfxInfoPointers        = 0x08505620,
    cb2Overworld           = 0x08085e5c,
    gObjectEvents          = 0x02037350,
    gPlayerAvatar          = 0x02037590,
    gSprites               = 0x02020630,
    gSpriteCoordOffsetX    = 0x02021bbc,
    gSpriteCoordOffsetY    = 0x02021bbe,
    sSpriteTileAllocBitmap = 0x02021b3c,
    gReservedSpriteTileCnt = 0x02021b3a,
    gMapHeader             = 0x02037318,
    gMainCallback2         = 0x030022c4,
    gSaveBlock1Ptr         = 0x03005d8c,
    gSaveBlock2Ptr         = 0x03005d90,
    gFieldCameraX          = 0x03005de0,
    gFieldCameraY          = 0x03005de4,
}

local OBJECTEVENT_SIZE = 0x24
local MAP_GROUPS_COUNT = 34   -- the adapter's bound, unmeasured
local MAP_OFFSET = 7          -- ObjectEvent.currentCoords carry it; SaveBlock1.pos does not
local PLAYERAVATAR_FROM_OBJECTS = 0x240 -- vanilla RELATION, verified below, never assumed

-- The adapter's BRENDAN_PAL_REF_BYTES, the first four bytes of Brendan's palette, and nothing longer: a tile block
-- here would be an asset dump.
local PAL_SEED = { 0x0e, 0x53, 0x5f, 0x5b }

-- ROM bounds: ask the host, and say which path was taken, so a null result never reads as "searched everywhere".

local ROM_BOUND_FALLBACK = 0x1000000
local romSize, romSizeSource
if type(memory.getmemorydomainsize) == "function" then
    local ok, sz = pcall(memory.getmemorydomainsize, "ROM")
    if ok and type(sz) == "number" and sz > 0 then
        romSize, romSizeSource = sz, "memory.getmemorydomainsize('ROM')"
    end
end
if not romSize then
    -- This host does not answer getmemorydomainsize, and 16 MB is half a 32 MB cartridge. Cartridge space mirrors, so
    -- sample both halves: any pair that differs, ignoring all-00 and all-FF, means the upper half is real.
    local upperIsReal = false
    for _, off in ipairs({ 0x4, 0x1000, 0x40000, 0x200000, 0x700000, 0xA00000, 0xF00000 }) do
        local lo = memory.read_u32_le(0x08000000 + off)
        local hi = memory.read_u32_le(0x09000000 + off)
        if hi ~= lo and hi ~= 0 and hi ~= 0xFFFFFFFF then
            upperIsReal = true
            break
        end
    end
    if upperIsReal then
        romSize, romSizeSource = 0x2000000, "MEASURED by half-mirror comparison (32MB cart)"
    else
        romSize, romSizeSource = ROM_BOUND_FALLBACK, "FALLBACK, upper half mirrors the lower (16MB)"
    end
end
if romSize > 0x2000000 then romSize = 0x2000000 end
local ROM_END = V.romBase + romSize

-- Phases of fixed length, with a countdown to the console and nothing to time.

local CH_CKSUM = 0x8000    -- 32 KB/frame, full byte coverage
local CH_PAL   = 0x10000   -- 64 KB/frame, halfword-aligned candidates
local CH_TABLE = 0x20000   -- 128 KB/frame, word-aligned candidates (the adapter's own slice size)
local CH_EWRAM = 0x20000

local LIVE_FRAMES = 900    -- ~15s of live sampling; retried every frame until it succeeds

local frame = 0
local phase = 1
local phaseFrame = 0
local lastCountdown = -1

local result = {}   -- name -> { state = "RESOLVED"/"AMBIGUOUS"/"UNRESOLVED", ... }

local function record(name, state, detail, addr, shift)
    result[#result + 1] = { name = name, state = state, detail = detail, addr = addr, shift = shift }
end

-- Phase 1: identity, and every literal the adapter would use.

local function romString(addr, n)
    local out = {}
    for i = 0, n - 1 do
        local b = r8(addr + i)
        -- Printable ASCII only: a patched header is often padded with 00 or garbage; the hex dump keeps the value.
        out[#out + 1] = (b >= 0x20 and b < 0x7f) and string.char(b) or "."
    end
    return table.concat(out)
end

local function romHexRun(addr, n)
    local out = {}
    for i = 0, n - 1 do out[#out + 1] = string.format("%02X", r8(addr + i)) end
    return table.concat(out, " ")
end

local function phaseIdentity()
    loud("=== ROM HEADER IDENTITY (GBATEK cartridge header) ===")
    loud(string.format("  title      0x080000A0 : <%s>  [%s]",
        romString(0x080000a0, 12), romHexRun(0x080000a0, 12)))
    loud(string.format("  game code  0x080000AC : <%s>  [%s]",
        romString(0x080000ac, 4), romHexRun(0x080000ac, 4)))
    loud(string.format("  maker code 0x080000B0 : <%s>  [%s]",
        romString(0x080000b0, 2), romHexRun(0x080000b0, 2)))
    loud(string.format("  version    0x080000BC : 0x%02X", r8(0x080000bc)))
    loud(string.format("  ROM bound  %s..%s  (%d MB, from %s)",
        hex(V.romBase), hex(ROM_END - 1), romSize // 0x100000, romSizeSource))
    -- A patch can leave title and game code untouched, so the header alone is no identity: hence the checksum.
    say("  NOTE: header alone does not identify a build -- patches commonly leave it unchanged.")

    say("")
    say("=== CODE-SITE LITERALS, READ AS-IS ===")
    say("Every line is `the address meshghost_emerald.lua would use` -> `what is there right now`.")
    say("None of these can be found by a ROM byte search (they are runtime RAM, or code), so they")
    say("are reported for a human to compare against a vanilla run, not resolved here.")
    local literals = {
        { "gSprites (EWRAM array)", V.gSprites, "u32" },
        { "gSpriteCoordOffsetX", V.gSpriteCoordOffsetX, "s16" },
        { "gSpriteCoordOffsetY", V.gSpriteCoordOffsetY, "s16" },
        { "sSpriteTileAllocBitmap", V.sSpriteTileAllocBitmap, "u32" },
        { "gReservedSpriteTileCount", V.gReservedSpriteTileCnt, "u16" },
        { "gMapHeader", V.gMapHeader, "u32" },
        { "gMain.callback2", V.gMainCallback2, "u32" },
        { "gSaveBlock1Ptr", V.gSaveBlock1Ptr, "u32" },
        { "gSaveBlock2Ptr", V.gSaveBlock2Ptr, "u32" },
        { "gFieldCamera.x", V.gFieldCameraX, "u32" },
        { "gFieldCamera.y", V.gFieldCameraY, "u32" },
    }
    for _, l in ipairs(literals) do
        local v
        if l[3] == "u32" then v = string.format("%08X", r32(l[2]))
        elseif l[3] == "s16" then v = string.format("%d", rs16(l[2]))
        else v = string.format("%04X", r16(l[2])) end
        say(string.format("  %-26s %s -> %s %s", l[1], hex(l[2]), l[3], v))
    end
    say("  gSprites cannot be byte-searched (runtime array). probes/gsprites_scan_probe.lua is")
    say("  the instrument that locates it live; run it separately on this ROM.")
    say("")
end

-- Phase 2: a bounded FNV-1a/32 checksum across frames, with a per-megabyte digest to compare builds region by region.

local ck = { at = V.romBase, whole = 2166136261, mb = 2166136261, mbIndex = 0, lines = {} }

local function ckStep()
    local n = math.min(CH_CKSUM, ROM_END - ck.at)
    local b = memory.read_bytes_as_array(ck.at, n)
    local w, m = ck.whole, ck.mb
    for i = 1, n do
        local by = b[i]
        w = ((w ~ by) * 16777619) & 0xFFFFFFFF
        m = ((m ~ by) * 16777619) & 0xFFFFFFFF
    end
    ck.whole, ck.mb = w, m
    ck.at = ck.at + n
    if (ck.at - V.romBase) % 0x100000 == 0 or ck.at >= ROM_END then
        ck.lines[#ck.lines + 1] = string.format("  MB %02d  %08X", ck.mbIndex, ck.mb)
        ck.mbIndex = ck.mbIndex + 1
        ck.mb = 2166136261
    end
    if ck.at >= ROM_END then
        loud(string.format("=== ROM CHECKSUM (FNV-1a/32 over %s..%s) = %08X ===",
            hex(V.romBase), hex(ROM_END - 1), ck.whole))
        say("Per-megabyte digests (for diffing two builds region by region):")
        for _, l in ipairs(ck.lines) do say(l) end
        say("")
        return true
    end
    return false
end

-- Phase 3: the character palette block, by the seed bytes and then a check that the 32 bytes are a 16-colour palette
-- (BGR555 never sets bit 15).

local pal = { at = V.romBase, hits = {}, raw = 0 }

local function palLooksLikePalette(a)
    for i = 0, 15 do
        if (r16(a + i * 2) & 0x8000) ~= 0 then return false end
    end
    return true
end

local function palStep()
    local n = math.min(CH_PAL, ROM_END - pal.at)
    local b = memory.read_bytes_as_array(pal.at, n)
    local s1, s2, s3, s4 = PAL_SEED[1], PAL_SEED[2], PAL_SEED[3], PAL_SEED[4]
    -- Halfword stride, so an odd-aligned copy is missed, and the log says so.
    for i = 1, n - 3, 2 do
        if b[i] == s1 and b[i + 1] == s2 and b[i + 2] == s3 and b[i + 3] == s4 then
            pal.raw = pal.raw + 1
            local a = pal.at + i - 1
            if palLooksLikePalette(a) then pal.hits[#pal.hits + 1] = a end
        end
    end
    pal.at = pal.at + n
    if pal.at < ROM_END then return false end

    say("=== ANCHOR: gObjectEventPal_Brendan (character palette block) ===")
    say(string.format("  seed = 4 bytes, halfword-aligned, searched %s..%s; %d raw byte matches, "
        .. "%d survived the palette-structure check", hex(V.romBase), hex(ROM_END - 1),
        pal.raw, #pal.hits))
    for _, a in ipairs(pal.hits) do
        say(string.format("    candidate %s   shift vs vanilla %s = %s0x%X", hex(a),
            hex(V.palBrendan), a >= V.palBrendan and "+" or "-", math.abs(a - V.palBrendan)))
    end
    if #pal.hits == 0 then
        loud("ANCHOR palette: UNRESOLVED -- no candidate. This build's character palette differs "
            .. "from vanilla's, or the block moved AND changed. Nothing may be assumed.")
        record("gObjectEventPal_Brendan", "UNRESOLVED", "no candidate matched the seed")
    elseif #pal.hits > 1 then
        loud(string.format("ANCHOR palette: AMBIGUOUS -- %d candidates, listed in the log. "
            .. "NOT choosing one.", #pal.hits))
        record("gObjectEventPal_Brendan", "AMBIGUOUS", #pal.hits .. " candidates")
    else
        local a = pal.hits[1]
        loud(string.format("ANCHOR palette: RESOLVED %s (shift %s0x%X)", hex(a),
            a >= V.palBrendan and "+" or "-", math.abs(a - V.palBrendan)))
        record("gObjectEventPal_Brendan", "RESOLVED", "single candidate", a, a - V.palBrendan)
        -- The block moved as one on Archipelago, so the same shift for the other five is a prediction to check, never a
        -- resolution: a build that split the block makes these lines wrong.
        local d = a - V.palBrendan
        for _, q in ipairs({ { "gObjectEventPal_May", V.palMay },
                             { "gObjectEventPic_BrendanNormal", V.picBrendanNormal },
                             { "gObjectEventPic_BrendanRunning", V.picBrendanRunning } }) do
            say(string.format("    PREDICTED (same shift, unverified) %-32s %s", q[1], hex(q[2] + d)))
        end
    end
    say("")
    return true
end

-- Phase 4: gObjectEventGraphicsInfoPointers, purely structural: runs of word-aligned ROM pointers whose targets
-- validate as graphics info under graphicsInfo()'s rules. The spawn path indexes it, so a wrong one is a bad write.

local gt = { at = V.romBase, runStart = nil, runLen = 0, cands = {}, prevTailRun = 0 }

local RUN_MIN = 48        -- a conservative floor: far shorter than the real table, long enough
                          -- that ordinary data does not produce one by accident
local VALIDATE_MIN = 32   -- entries that must fully validate as graphics info
local SIZE_MAX = 0x2000   -- an overworld graphic's image size; a sanity ceiling, not a claim

local function gfxEntryValid(ptr)
    if not isRomPtr(ptr) then return false end
    local size = r16(ptr + 0x06)
    if size == 0 or size > SIZE_MAX or (size % 32) ~= 0 then return false end
    local w, h = r16(ptr + 0x08), r16(ptr + 0x0a)
    if not (w == 8 or w == 16 or w == 32 or w == 64) then return false end
    if not (h == 8 or h == 16 or h == 32 or h == 64) then return false end
    local anims, images = r32(ptr + 0x18), r32(ptr + 0x1c)
    if not isRomPtr(anims) or not isRomPtr(images) then return false end
    local oam, subs, affine = r32(ptr + 0x10), r32(ptr + 0x14), r32(ptr + 0x20)
    if oam ~= 0 and not isRomPtr(oam) then return false end
    if subs ~= 0 and not isRomPtr(subs) then return false end
    if affine ~= 0 and not isRomPtr(affine) then return false end
    return true
end

local function gtCloseRun()
    if gt.runStart and gt.runLen >= RUN_MIN then
        gt.cands[#gt.cands + 1] = { base = gt.runStart, len = gt.runLen }
    end
    gt.runStart, gt.runLen = nil, 0
end

local function gtStep()
    local n = math.min(CH_TABLE, ROM_END - gt.at)
    local b = memory.read_bytes_as_array(gt.at, n)
    -- A ROM pointer has 0x08 or 0x09 as its high byte; the costly validation runs only on surviving runs.
    for i = 1, n - 3, 4 do
        local hi = b[i + 3]
        if hi == 0x08 or hi == 0x09 then
            if not gt.runStart then gt.runStart = gt.at + i - 1 gt.runLen = 0 end
            gt.runLen = gt.runLen + 1
        else
            gtCloseRun()
        end
    end
    gt.at = gt.at + n
    if gt.at < ROM_END then return false end
    gtCloseRun()

    say("=== ANCHOR: gObjectEventGraphicsInfoPointers (the spawn path's graphics table) ===")
    say(string.format("  structural search, no seed bytes: %d runs of >= %d consecutive ROM "
        .. "pointers found in %s..%s", #gt.cands, RUN_MIN, hex(V.romBase), hex(ROM_END - 1)))
    local survivors = {}
    for _, c in ipairs(gt.cands) do
        local valid, checked = 0, math.min(c.len, 96)
        for i = 0, checked - 1 do
            if gfxEntryValid(r32(c.base + i * 4)) then valid = valid + 1 end
        end
        say(string.format("    run at %s  len %d words  -> %d/%d entries validate as "
            .. "ObjectEventGraphicsInfo", hex(c.base), c.len, valid, checked))
        if valid >= VALIDATE_MIN then
            survivors[#survivors + 1] = { base = c.base, valid = valid, checked = checked }
        end
    end
    if #survivors == 0 then
        loud("ANCHOR graphics table: UNRESOLVED -- no run validated. The adapter's spawn path "
            .. "must not run on this build.")
        record("gObjectEventGraphicsInfoPointers", "UNRESOLVED", "no run validated")
    elseif #survivors > 1 then
        loud(string.format("ANCHOR graphics table: AMBIGUOUS -- %d runs validated, listed in the "
            .. "log. NOT choosing one.", #survivors))
        for _, s in ipairs(survivors) do
            say(string.format("    AMBIGUOUS candidate %s (%d/%d)", hex(s.base), s.valid, s.checked))
        end
        record("gObjectEventGraphicsInfoPointers", "AMBIGUOUS", #survivors .. " candidates")
    else
        local s = survivors[1]
        loud(string.format("ANCHOR graphics table: RESOLVED %s (%d/%d entries validate, shift "
            .. "%s0x%X)", hex(s.base), s.valid, s.checked,
            s.base >= V.gfxInfoPointers and "+" or "-", math.abs(s.base - V.gfxInfoPointers)))
        record("gObjectEventGraphicsInfoPointers", "RESOLVED",
            string.format("%d/%d validate", s.valid, s.checked), s.base, s.base - V.gfxInfoPointers)
        -- The palette and the table are different address families: one shift for both means the region moved whole,
        -- two mean no single ROM-wide offset applies.
        local pshift = (#pal.hits == 1) and (pal.hits[1] - V.palBrendan) or nil
        if pshift then
            local tshift = s.base - V.gfxInfoPointers
            say(string.format("  cross-check: palette shift 0x%X vs table shift 0x%X -- %s",
                pshift, tshift, pshift == tshift and "SAME (one relocated region)"
                or "DIFFERENT (no single ROM-wide offset; resolve each anchor separately)"))
        end
    end
    say("")
    return true
end

-- Phase 5: the live anchors, runtime RAM, by structural search of EWRAM and IWRAM with a two-way cross-link each.
-- Retried every frame of the phase: during the intro or title nothing is there yet.

local EWRAM_BASE, EWRAM_SIZE = 0x02000000, 0x00040000
local IWRAM_BASE, IWRAM_SIZE = 0x03000000, 0x00008000

local live = {
    at = EWRAM_BASE, pobjHits = {}, done = false,
    cb2 = {}, cb2Order = {},
    objBase = nil, playerObj = nil, playerIdx = nil,
    sb1Ptr = nil, sb1Cands = {},
}

-- Active, isPlayer, LOCALID_PLAYER and a plausible map group, as the adapter's playerObjEventExistsAt() requires:
-- a repeating garbage pattern satisfies any one of them by chance.
local function looksLikePlayerObj(a)
    return (r8(a + 0x00) & 0x01) == 1
        and (r8(a + 0x02) & 0x01) == 1
        and r8(a + 0x08) == 0xff
        and r8(a + 0x0a) < MAP_GROUPS_COUNT
end

local function liveScanEwram()
    live.pobjHits = {}
    local a = EWRAM_BASE
    while a < EWRAM_BASE + EWRAM_SIZE do
        local n = math.min(CH_EWRAM, EWRAM_BASE + EWRAM_SIZE - a)
        local b = memory.read_bytes_as_array(a, n)
        for i = 1, n - 0x24, 4 do
            if (b[i] & 0x01) == 1 and (b[i + 2] & 0x01) == 1
                and b[i + 8] == 0xff and b[i + 10] < MAP_GROUPS_COUNT then
                live.pobjHits[#live.pobjHits + 1] = a + i - 1
            end
        end
        a = a + n
    end
end

-- The base is the candidate minus its index times the entry size, the index confirmed by gPlayerAvatar.objectEventId
-- pointing back with non-zero flags, which also checks the +0x240 relation survived this build.
local function resolveObjBase()
    local out = {}
    for _, a in ipairs(live.pobjHits) do
        for idx = 0, 15 do
            local base = a - idx * OBJECTEVENT_SIZE
            if base >= EWRAM_BASE then
                local av = base + PLAYERAVATAR_FROM_OBJECTS
                if r8(av + 0x05) == idx and r8(av + 0x00) ~= 0 and r8(av + 0x04) < 64 then
                    out[#out + 1] = { base = base, idx = idx, obj = a, avatar = av }
                end
            end
        end
    end
    return out
end

-- An IWRAM word pointing into EWRAM at a target agreeing with the player's object event on both coordinates (the
-- save block has no +7 map offset) and the map group.
local function resolveSaveBlockPtr()
    if not live.playerObj then return {} end
    local ox = rs16(live.playerObj + 0x10) - MAP_OFFSET
    local oy = rs16(live.playerObj + 0x12) - MAP_OFFSET
    local og = r8(live.playerObj + 0x0a)
    local out = {}
    for a = IWRAM_BASE, IWRAM_BASE + IWRAM_SIZE - 4, 4 do
        local p = r32(a)
        if p >= EWRAM_BASE and p < EWRAM_BASE + EWRAM_SIZE - 0x10 then
            if rs16(p + 0x00) == ox and rs16(p + 0x02) == oy and r8(p + 0x04) == og then
                out[#out + 1] = { at = a, target = p }
            end
        end
    end
    return out
end

local function liveStep()
    -- callback2 at the vanilla site, as a histogram: not resolved, but the value dominating a long overworld sample is
    -- this build's CB2_Overworld candidate, and one sample during a warp or battle is a coin flip.
    local cb = r32(V.gMainCallback2)
    if not live.cb2[cb] then live.cb2[cb] = 0 live.cb2Order[#live.cb2Order + 1] = cb end
    live.cb2[cb] = live.cb2[cb] + 1

    if live.objBase then return end
    -- Runs only until it succeeds.
    liveScanEwram()
    local cands = resolveObjBase()
    if #cands == 0 then return end
    -- Several hits can describe one base, and one base found twice is one answer.
    local seen, uniq = {}, {}
    for _, c in ipairs(cands) do
        if not seen[c.base] then seen[c.base] = true uniq[#uniq + 1] = c end
    end
    live.cands = uniq
    if #uniq == 1 then
        live.objBase, live.playerIdx = uniq[1].base, uniq[1].idx
        live.playerObj, live.avatar = uniq[1].obj, uniq[1].avatar
        live.sb1Cands = resolveSaveBlockPtr()
        if #live.sb1Cands == 1 then live.sb1Ptr = live.sb1Cands[1].at end
    end
end

local function liveReport()
    say("=== ANCHOR: gObjectEvents / gPlayerAvatar (runtime EWRAM arrays) ===")
    say(string.format("  structural EWRAM search over %s..%s; %d player-object-event byte "
        .. "signatures, %d survived the two-way gPlayerAvatar cross-link",
        hex(EWRAM_BASE), hex(EWRAM_BASE + EWRAM_SIZE - 1), #live.pobjHits,
        live.cands and #live.cands or 0))
    if live.cands then
        for _, c in ipairs(live.cands) do
            say(string.format("    candidate gObjectEvents %s (player at index %d, %s); "
                .. "gPlayerAvatar %s", hex(c.base), c.idx, hex(c.obj), hex(c.avatar)))
        end
    end
    if not live.cands or #live.cands == 0 then
        loud("ANCHOR gObjectEvents: UNRESOLVED -- nothing matched. Either the run never reached "
            .. "the overworld with a loaded save, or this build lays the array out differently.")
        record("gObjectEvents", "UNRESOLVED", "no candidate (was the overworld reached?)")
    elseif #live.cands > 1 then
        loud(string.format("ANCHOR gObjectEvents: AMBIGUOUS -- %d candidates. NOT choosing one.",
            #live.cands))
        record("gObjectEvents", "AMBIGUOUS", #live.cands .. " candidates")
    else
        local c = live.cands[1]
        loud(string.format("ANCHOR gObjectEvents: RESOLVED %s (shift %s0x%X); gPlayerAvatar %s "
            .. "(+0x%X relation HOLDS on this build)", hex(c.base),
            c.base >= V.gObjectEvents and "+" or "-", math.abs(c.base - V.gObjectEvents),
            hex(c.avatar), PLAYERAVATAR_FROM_OBJECTS))
        record("gObjectEvents", "RESOLVED", "player at index " .. c.idx, c.base,
            c.base - V.gObjectEvents)
        record("gPlayerAvatar", "RESOLVED", "verified +0x240 from gObjectEvents", c.avatar,
            c.avatar - V.gPlayerAvatar)
    end
    say("")

    say("=== ANCHOR: gSaveBlock1Ptr (IWRAM pointer) ===")
    say(string.format("  IWRAM %s..%s, word-aligned; a candidate must point into EWRAM AND agree "
        .. "with the player's object event on x, y and map group",
        hex(IWRAM_BASE), hex(IWRAM_BASE + IWRAM_SIZE - 1)))
    for _, c in ipairs(live.sb1Cands or {}) do
        say(string.format("    candidate %s -> SaveBlock1 at %s", hex(c.at), hex(c.target)))
    end
    if not live.sb1Cands or #live.sb1Cands == 0 then
        loud("ANCHOR gSaveBlock1Ptr: UNRESOLVED -- no candidate (needs gObjectEvents resolved "
            .. "and a loaded save).")
        record("gSaveBlock1Ptr", "UNRESOLVED", "no candidate")
    elseif #live.sb1Cands > 1 then
        loud(string.format("ANCHOR gSaveBlock1Ptr: AMBIGUOUS -- %d candidates. NOT choosing one.",
            #live.sb1Cands))
        record("gSaveBlock1Ptr", "AMBIGUOUS", #live.sb1Cands .. " candidates")
    else
        local c = live.sb1Cands[1]
        loud(string.format("ANCHOR gSaveBlock1Ptr: RESOLVED %s (shift %s0x%X)", hex(c.at),
            c.at >= V.gSaveBlock1Ptr and "+" or "-", math.abs(c.at - V.gSaveBlock1Ptr)))
        record("gSaveBlock1Ptr", "RESOLVED", "target " .. hex(c.target), c.at,
            c.at - V.gSaveBlock1Ptr)
        -- gSaveBlock2Ptr follows gSaveBlock1Ptr in vanilla: an observation only, since playerGender reading 0 or 1 is
        -- one weak bit of evidence.
        local p2 = r32(c.at + 4)
        local g = (p2 >= EWRAM_BASE and p2 < EWRAM_BASE + EWRAM_SIZE) and r8(p2 + 0x08) or nil
        say(string.format("  gSaveBlock2Ptr (vanilla sits at +4): word there = %s, playerGender "
            .. "byte = %s -- OBSERVATION ONLY, not resolved", hex(p2),
            g and tostring(g) or "n/a"))
    end
    say("")

    say("=== OBSERVATION: gMain.callback2 values seen (vanilla code site " .. hex(V.gMainCallback2)
        .. ") ===")
    say("  The dominant value across a long overworld sample is this build's CB2_Overworld")
    say("  candidate. It is an OBSERVATION -- the site it was read from is a vanilla literal, so")
    say("  a build that moved gMain itself makes every line below meaningless. Compare against a")
    say("  vanilla run before believing it.")
    local best, bestN = nil, -1
    for _, v in ipairs(live.cb2Order) do
        local n = live.cb2[v]
        say(string.format("    %s  x%d frames%s", hex(v), n,
            (v == V.cb2Overworld or v == V.cb2Overworld + 1) and "   <- VANILLA CB2_Overworld" or ""))
        if n > bestN then best, bestN = v, n end
    end
    if best then
        loud(string.format("callback2 dominant value: %s (%d/%d frames)%s", hex(best), bestN,
            LIVE_FRAMES, isRomPtr(best) and "" or "   -- NOT a ROM pointer, suspect"))
    end
    say("")
end

-- Phase 6: the report.

local function finalReport()
    loud("=== SUMMARY ===")
    for _, r in ipairs(result) do
        local line = string.format("  %-34s %-11s %s", r.name, r.state, r.detail or "")
        if r.addr then
            line = line .. string.format("  at %s (shift %s0x%X)", hex(r.addr),
                r.shift >= 0 and "+" or "-", math.abs(r.shift))
        end
        loud(line)
    end
    loud("Nothing above was chosen for you: AMBIGUOUS and UNRESOLVED are results, not failures.")
    loud("Full detail, including every rejected candidate, is in " .. logPath)
end

-- One chunk per frame, a countdown to the console, then silence.

local function countdown(label, doneUnits, totalUnits)
    local pct = math.floor(doneUnits * 100 / math.max(totalUnits, 1))
    if pct >= lastCountdown + 10 then
        lastCountdown = pct - (pct % 10)
        console.log(string.format("romvariant: %s %d%%", label, lastCountdown))
    end
end

local function tick()
    frame = frame + 1
    phaseFrame = phaseFrame + 1

    if phase == 1 then
        phaseIdentity()
        phase, phaseFrame, lastCountdown = 2, 0, -1
        console.log("romvariant: phase 2/5 -- ROM checksum, about "
            .. math.ceil(romSize / CH_CKSUM / 60) .. "s. Nothing to do.")
    elseif phase == 2 then
        countdown("checksum", ck.at - V.romBase, romSize)
        if ckStep() then
            phase, phaseFrame, lastCountdown = 3, 0, -1
            console.log("romvariant: phase 3/5 -- palette anchor search, about "
                .. math.ceil(romSize / CH_PAL / 60) .. "s.")
        end
    elseif phase == 3 then
        countdown("palette search", pal.at - V.romBase, romSize)
        if palStep() then
            phase, phaseFrame, lastCountdown = 4, 0, -1
            console.log("romvariant: phase 4/5 -- graphics-table anchor search, about "
                .. math.ceil(romSize / CH_TABLE / 60) .. "s.")
        end
    elseif phase == 4 then
        countdown("graphics table", gt.at - V.romBase, romSize)
        if gtStep() then
            phase, phaseFrame, lastCountdown = 5, 0, -1
            console.log(string.format("romvariant: phase 5/5 -- LIVE anchors, %ds. Be in the "
                .. "overworld in a loaded save; walking around is fine, nothing to press.",
                LIVE_FRAMES // 60))
        end
    elseif phase == 5 then
        liveStep()
        if phaseFrame % 60 == 0 then
            console.log(string.format("romvariant: live anchors, %ds left%s",
                (LIVE_FRAMES - phaseFrame) // 60,
                live.objBase and "  (gObjectEvents found)" or "  (not found yet)"))
        end
        if phaseFrame >= LIVE_FRAMES then
            liveReport()
            finalReport()
            phase = 6
        end
    end
    -- Done, and silent: a probe that keeps talking scrolls its own answer out of the console.
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function()
        if fh then fh:close() fh = nil end
        console.log("romvariant: unloaded")
    end
else
    while true do tick() emu.frameadvance() end
end
