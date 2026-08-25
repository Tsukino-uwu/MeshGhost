-- MeshGhost -- identify an Emerald-derived ROM and RESOLVE its anchors by search (DEV TOOL,
-- never shipped, never wired into meshghost_emerald.lua)
--
-- READ-ONLY. It writes no game memory, no ROM, no save, no savestate; it presses nothing
-- (`joypad.set` is never called) and it draws nothing, so what is on screen is exactly what the
-- player is doing. Its only output is the Lua Console and a timestamped log beside this file.
--
-- WHY THIS EXISTS
-- `meshghost_emerald.lua` today chooses between exactly TWO known layouts: vanilla, or the one
-- Archipelago Emerald base patch it was measured against, by testing a couple of known addresses
-- (detectSpriteAddrOffset / tryDetectAvatarAddrOffset, and their headers). That is a two-entry
-- table wearing the clothes of a detector: on SPEEDCHOICE, EX SPEEDCHOICE, or any Archipelago
-- world revision that recompiles differently, both tests fail, the adapter falls back to vanilla
-- addresses with a warning, and it then reads -- and, on the spawn path, WRITES -- whatever now
-- lives there. This probe is the runtime half of fixing that: it asks an UNKNOWN Emerald-derived
-- ROM where its anchors actually are, by searching for them, and reports what it found without
-- deciding anything.
--
-- WHAT IT MAY ASSUME, AND WHAT IT MAY NOT
-- It may assume STRUCTURE -- the layouts of `struct ObjectEventGraphicsInfo`, `struct
-- ObjectEvent`, `struct PlayerAvatar` and `struct SaveBlock1`, every field of which is already
-- used and cited in the shipped adapter (see its GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR /
-- graphicsInfo() / playerObjEventExistsAt() / getLocalState() and their headers) -- plus the GBA
-- cartridge header layout, which is hardware documentation (GBATEK, "GBA Cartridge Header":
-- title at 0x080000A0 (12 bytes), game code 0x080000AC (4), maker code 0x080000B0 (2), software
-- version 0x080000BC (1)).
-- It may NOT assume ADDRESSES. Every vanilla address below is used for exactly two things: as a
-- LABEL to print a shift against, and -- for the anchors no search can reach -- as a code site
-- whose literal and current value are logged verbatim for a human to compare against vanilla.
-- Nothing in any search is seeded with one.
--
-- WHAT IT WILL NOT DO
-- It never picks a winner from several. Every anchor is reported as RESOLVED (exactly one
-- candidate survived), AMBIGUOUS (more than one did -- every one is printed), or UNRESOLVED (none
-- did). Silently choosing the first match is how a two-entry table becomes a wrong address, which
-- is the whole failure this probe exists to prevent.
--
-- BUDGET (adapters/_template/probes.md, "A probe's read budget is real")
-- Every wide pass is CHUNKED across frames at roughly the same cost as the adapter's own
-- gMapGroups scan -- one `memory.read_bytes_as_array` per frame and about 32k Lua iterations over
-- it. Nothing here scans anything in a blocking loop, so the game keeps running at speed while it
-- works.
--
-- TIMING (probes.md's hard rule: endurance, not timing)
-- Fixed-length phases with a countdown printed to the console. There is no moment to hit and
-- nothing to press. The one thing that helps: be IN THE OVERWORLD, in a loaded save, by the time
-- the live phase starts (the console says when, with a countdown) -- the live anchors only exist
-- once the map and object systems are running. If you are not, the run still finishes and says
-- so, and re-running costs one control-file write.
--
-- HOW TO RUN
--   Point `dev-scripts/bizhawk-dev-loader.target` at this file (`agent_docs/environment.md`), or
--   open it directly in the Lua Console. Results go to the console and to
--   `romvariant_probe_<timestamp>.log` beside this script; the log is authoritative and uncapped,
--   the console gets the headlines.

----------------------------------------------------------------------------
-- Logging and paths -- same shape as dive_probe.lua, including the built
-- backslash: this emulator build's Lua rejects the escaped form (2026-08-21).
----------------------------------------------------------------------------

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

----------------------------------------------------------------------------
-- Vanilla labels. LABELS, not inputs -- see the header. Every one of these is
-- already in meshghost_emerald.lua with its own citation.
----------------------------------------------------------------------------

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
local MAP_GROUPS_COUNT = 34   -- include/constants/map_groups.h, as cited in the adapter
local MAP_OFFSET = 7          -- ObjectEvent.currentCoords carry it; SaveBlock1.pos does not
local PLAYERAVATAR_FROM_OBJECTS = 0x240 -- vanilla RELATION, verified below, never assumed

-- The one byte-literal seed in this file, and it is already committed and cited in the shipped
-- adapter (BRENDAN_PAL_REF_BYTES -- the first four bytes of gObjectEventPal_Brendan, read
-- directly from the vanilla ROM file 2026-08-14). Four bytes of a palette is a fact about where
-- something is, not game expression; nothing longer is embedded here on purpose, because a
-- 256-byte tile block copied into this repo would be a verbatim asset dump (CLAUDE.md).
local PAL_SEED = { 0x0e, 0x53, 0x5f, 0x5b }

----------------------------------------------------------------------------
-- ROM bounds. ASK the host rather than assuming a size (probes.md, "Ask the
-- host what it has"); fall back to 16 MB and SAY which path was taken, so a
-- null search result can never be read as "searched everywhere".
----------------------------------------------------------------------------

local ROM_BOUND_FALLBACK = 0x1000000
local romSize, romSizeSource
if type(memory.getmemorydomainsize) == "function" then
    local ok, sz = pcall(memory.getmemorydomainsize, "ROM")
    if ok and type(sz) == "number" and sz > 0 then
        romSize, romSizeSource = sz, "memory.getmemorydomainsize('ROM')"
    end
end
if not romSize then
    romSize, romSizeSource = ROM_BOUND_FALLBACK, "FALLBACK (host did not report a ROM size)"
end
if romSize > 0x2000000 then romSize = 0x2000000 end
local ROM_END = V.romBase + romSize

----------------------------------------------------------------------------
-- Phase machine. Fixed lengths, countdown to the console, nothing to time.
----------------------------------------------------------------------------

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

----------------------------------------------------------------------------
-- PHASE 1 -- identity, and every literal this adapter would use.
----------------------------------------------------------------------------

local function romString(addr, n)
    local out = {}
    for i = 0, n - 1 do
        local b = r8(addr + i)
        -- Printable ASCII only. A patched header is routinely padded with 0x00 or garbage, and
        -- a raw byte in a log line is unreadable; the hex dump beside it keeps the real value.
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
    -- The header is NOT an identity on its own: an Archipelago or SPEEDCHOICE patch can leave
    -- title and game code untouched, so two different builds share one header. That is exactly
    -- why the checksum below exists, and why nothing here branches on the header.
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

----------------------------------------------------------------------------
-- PHASE 2 -- bounded ROM checksum, computed incrementally across frames.
-- FNV-1a/32. Also a per-megabyte digest, so two builds that differ in one
-- region can be compared without re-running anything.
----------------------------------------------------------------------------

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

----------------------------------------------------------------------------
-- PHASE 3 -- ANCHOR 1: the overworld character palette block.
-- Byte-signature search for the four seed bytes, then a STRUCTURAL check that
-- the 32 bytes there really are a GBA 16-colour palette (every halfword's bit
-- 15 clear -- BGR555 has no bit 15). Every surviving candidate is printed.
----------------------------------------------------------------------------

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
    -- Halfword stride: a palette is a halfword-aligned block. Stated rather than assumed-away --
    -- an odd-aligned copy of these bytes would be missed, and that exclusion is in the log.
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
        -- The whole character graphics/palette block moved together on the one Archipelago build
        -- this project measured (all six addresses by the same delta -- meshghost_emerald.lua's
        -- SPRITE_ADDR_ARCHIPELAGO_SHIFT header). So the same shift applied to the other five is a
        -- PREDICTION worth printing and worth checking, never a resolution: if this build split
        -- that block, these lines are wrong and only a per-address check would say so.
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

----------------------------------------------------------------------------
-- PHASE 4 -- ANCHOR 2: gObjectEventGraphicsInfoPointers.
-- PURELY STRUCTURAL, no seed bytes at all: find every run of >= RUN_MIN
-- consecutive word-aligned ROM pointers, then keep only those whose targets
-- validate as `struct ObjectEventGraphicsInfo` under exactly the rules the
-- shipped graphicsInfo() already enforces before handing a pointer to the
-- engine. This is the table the spawn path indexes, so getting it wrong is
-- not a wrong picture, it is a write of engine-dereferenced garbage.
----------------------------------------------------------------------------

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
    -- Cheap pre-filter: a word is "a ROM pointer" iff its high byte is 0x08 or 0x09. One byte
    -- test per word, no dereference -- the expensive validation runs only on surviving runs.
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
        -- CROSS-CHECK FROM AN INDEPENDENT DIRECTION (probes.md, move 5). The palette block and
        -- the pointer table are different address families in vanilla -- if they shifted by the
        -- SAME amount on this build, that is a whole-region relocation and worth knowing; if
        -- they differ, no single ROM-wide offset applies and per-anchor resolution is mandatory.
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

----------------------------------------------------------------------------
-- PHASE 5 -- the LIVE anchors. Runtime RAM, so no ROM search can reach them.
-- Resolved by structural search of EWRAM/IWRAM instead, and every candidate
-- must satisfy a TWO-WAY cross-link, never a single field.
--
-- Retried every frame for the whole phase: a script loaded during the intro
-- or the title sequence finds nothing because nothing is there yet -- the
-- exact timing bug the adapter's own tryDetectAvatarAddrOffset() header
-- documents. Missing the window costs nothing here; the phase simply keeps
-- asking until it ends.
----------------------------------------------------------------------------

local EWRAM_BASE, EWRAM_SIZE = 0x02000000, 0x00040000
local IWRAM_BASE, IWRAM_SIZE = 0x03000000, 0x00008000

local live = {
    at = EWRAM_BASE, pobjHits = {}, done = false,
    cb2 = {}, cb2Order = {},
    objBase = nil, playerObj = nil, playerIdx = nil,
    sb1Ptr = nil, sb1Cands = {},
}

-- The player's own object event: active, isPlayer, LOCALID_PLAYER, and a plausible map group --
-- the same four facts the adapter's playerObjEventExistsAt() requires, and for the same reason
-- (a uniform repeating garbage pattern satisfies any one of them by coincidence).
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

-- Given a player-object-event candidate, the array BASE is that address minus its index times
-- the entry size -- and the index is not guessed, it is CONFIRMED from the other side:
-- gPlayerAvatar.objectEventId must point back at exactly that index, and gPlayerAvatar's flags
-- must be non-zero (a player is always in some avatar state). That also VERIFIES the +0x240
-- relation between the two arrays instead of assuming it survived this build's recompile.
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

-- gSaveBlock1Ptr: an IWRAM word holding a pointer into EWRAM whose target agrees with the
-- player's own object event on THREE independent facts -- both coordinates (SaveBlock1.pos does
-- not carry ObjectEvent's +7 map offset, which is itself a discriminator) and the map group.
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
    -- gMain.callback2, sampled at the VANILLA code site, as a histogram. It is not resolved --
    -- the site itself is a literal here -- but the value that dominates a long overworld sample
    -- IS this build's CB2_Overworld candidate, and the adapter's inOverworld() needs exactly
    -- that number. Sampling rather than reading once, because one sample of a value that
    -- changes during warps and battles is a coin flip (probes.md).
    local cb = r32(V.gMainCallback2)
    if not live.cb2[cb] then live.cb2[cb] = 0 live.cb2Order[#live.cb2Order + 1] = cb end
    live.cb2[cb] = live.cb2[cb] + 1

    if live.objBase then return end
    -- One EWRAM sweep per frame is ~64k cheap iterations spread over two bulk reads; it only
    -- runs until it succeeds, so the cost stops the moment the answer exists.
    liveScanEwram()
    local cands = resolveObjBase()
    if #cands == 0 then return end
    -- Collapse duplicates: several hits can describe one base (a map with the player plus a
    -- garbage look-alike), and the same base found twice is one answer, not two.
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
        -- gSaveBlock2Ptr sits immediately after gSaveBlock1Ptr in vanilla. Reported as an
        -- OBSERVATION with its plausibility, never as a resolution: playerGender being 0 or 1 is
        -- one weak bit of evidence, and one bit does not resolve an address.
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

----------------------------------------------------------------------------
-- PHASE 6 -- the report.
----------------------------------------------------------------------------

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

----------------------------------------------------------------------------
-- Tick. One chunk per frame, a countdown to the console, and then silence.
----------------------------------------------------------------------------

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
    -- phase 6: done, and deliberately silent. A probe that keeps talking after it has answered
    -- scrolls its own answer out of the console pane.
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
