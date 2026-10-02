-- Stage 1 of the VRAM/sprite-injection investigation, read-only: is there a contiguous run of OBJ VRAM tiles the
-- game never touches in ordinary vanilla play? It discovers candidate free regions rather than checking a guessed
-- address, and on every tile change compares two views: did the raw bytes ever change or go nonzero, and does the
-- game's sprite-tile allocator call the tile allocated right now? A tile that changes while the allocator calls it
-- free is a disagreement: something writes OBJ VRAM without going through the allocator.
-- The allocator bitmap has no symbol of its own; its address is derived as the 128 bytes between the end of
-- gReservedSpriteTileCount and gSpriteCoordOffsetX, read as tile n = bit n % 8 of byte n / 8, with the reserved count
-- reported separately. An OAM entry whose attr0 low byte (Y) is 160 or more is taken as parked. The overworld test
-- is two-way only (battle, menus and fades all read "not"), so each tile's first change also logs callback2.

local OBJ_VRAM0_ADDR = 0x06010000
local OBJ_VRAM0_SIZE = 0x8000
local OBJ_VRAM1_ADDR = 0x06014000 -- bitmap-mode OBJ tile 0 boundary
local TOTAL_OBJ_TILE_COUNT = 1024
local TILE_SIZE_4BPP = 32

local OBJ_PLTT_ADDR = 0x05000200
local OBJ_PALETTE_COUNT = 16
local PALETTE_SIZE = 32

local OAM_ADDR = 0x07000000
local OAM_ENTRY_COUNT = 128
local OAM_ENTRY_SIZE = 8
local DISPLAY_HEIGHT = 160

local GRESERVEDSPRITETILECOUNT_ADDR = 0x02021b3a
local SSPRITETILEALLOCBITMAP_ADDR = 0x02021b3c -- derived, see header
local GRESERVEDSPRITEPALETTECOUNT_ADDR = 0x0300301c

local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
-- Archipelago's CB2_Overworld: without it a patched ROM reads as outside the overworld all run.
local CB2_OVERWORLD_ARCHIPELAGO_ADDR = 0x080867f1

local REG_DISPCNT_ADDR = 0x04000000

local COARSE_INTERVAL_FRAMES = 1 -- how often the 16-block coarse hash pass runs
local REPORT_INTERVAL_FRAMES = 600 -- ~10s at 60fps
local BLOCK_SIZE = 2048
local BLOCK_COUNT = OBJ_VRAM0_SIZE / BLOCK_SIZE -- 16
local TILES_PER_BLOCK = BLOCK_SIZE / TILE_SIZE_4BPP -- 64

local function scriptDir()
    local ok, pwd = pcall(function() return io.popen and io.popen("cd"):read("*l") end)
    if not ok or not pwd or pwd == "" then
        return nil
    end
    return pwd .. "\\"
end

local logFile = nil
local logPath = nil
do
    local dir = scriptDir()
    if dir then
        logPath = dir .. "vram_probe_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
        local f, err = io.open(logPath, "w")
        if f then
            logFile = f
        else
            console.log("MeshGhost VRAM probe: could not open log file (" .. tostring(err) ..
                "), continuing console-only.")
        end
    else
        console.log("MeshGhost VRAM probe: could not resolve script directory, continuing console-only.")
    end
end

-- Console lines also go to the log, flushed at once: a session ends by closing the emulator. io.write takes only
-- strings, so values go through tostring() first.
local function logLine(msg)
    console.log(msg)
    if logFile then
        logFile:write(tostring(msg), "\n")
        logFile:flush()
    end
end

-- The memory domain and read tier: the domain list is read at startup and the VRAM/System Bus aliasing proven live.

-- getmemorydomainlist() returns a Lua table on this BizHawk build, whatever its doc string says; both shapes work.
local domainList = memory.getmemorydomainlist()
local domainNames = {}
if type(domainList) == "table" then
    for _, v in pairs(domainList) do
        table.insert(domainNames, tostring(v))
    end
else
    for name in tostring(domainList):gmatch("[^\r\n]+") do
        table.insert(domainNames, name)
    end
end

logLine("MeshGhost VRAM probe: available memory domains:")
logLine(table.concat(domainNames, ", "))

local DOMAIN = nil
for _, name in ipairs(domainNames) do
    if name == "VRAM" then
        DOMAIN = "VRAM"
    end
end

if DOMAIN == "VRAM" and type(memory.hash_region) == "function" then
    -- Prove the VRAM domain's address 0 really is System Bus 0x06010000 before trusting it,
    -- rather than assuming the mapping.
    local viaVram = memory.hash_region(0x10000, OBJ_VRAM0_SIZE, "VRAM")
    local viaBus = memory.hash_region(OBJ_VRAM0_ADDR, OBJ_VRAM0_SIZE, "System Bus")
    logLine(string.format("Aliasing check: hash_region(0x10000, VRAM) = %s", tostring(viaVram)))
    logLine(string.format("Aliasing check: hash_region(0x%08X, System Bus) = %s", OBJ_VRAM0_ADDR, tostring(viaBus)))
    if viaVram == viaBus then
        logLine("Aliasing check PASSED: VRAM domain offset 0x10000 == System Bus 0x06010000. Using System Bus for all reads (same domain the rest of this project already uses).")
    else
        logLine("Aliasing check FAILED or hashes not comparable -- falling back to System Bus at the documented address, but this is now unconfirmed. Investigate before trusting results.")
    end
elseif DOMAIN == "VRAM" then
    logLine("A 'VRAM' domain was reported but memory.hash_region is unavailable, so the aliasing check can't run. Using System Bus, unconfirmed against VRAM this session.")
else
    logLine("No 'VRAM' domain reported -- using 'System Bus', same as every other script in this project.")
end

if not memory.usememorydomain("System Bus") then
    logLine("ERROR: 'System Bus' memory domain not found on this core.")
    return
end

local TIER
if type(memory.read_bytes_as_array) == "function" and type(memory.hash_region) == "function" then
    TIER = "A"
elseif type(memory.hash_region) == "function" then
    TIER = "B"
else
    TIER = "C"
end
logLine("MeshGhost VRAM probe: selected read tier " .. TIER ..
    (TIER == "C" and " -- SAMPLED, NOT EXHAUSTIVE. Results from this run cannot prove a region is free." or ""))

if logPath then
    logLine("Log file: " .. logPath)
end

local tile = {}
for i = 0, TOTAL_OBJ_TILE_COUNT - 1 do
    tile[i] = {
        hash = nil,
        everNonzeroOw = false, everNonzeroNon = false,
        everChangedOw = false, everChangedNon = false,
        changeCount = 0,
        firstChangeFrame = nil, lastChangeFrame = nil, firstChangeCb2 = nil,
        everAllocated = false,
        disagreement = false,
    }
end

local blockHash = {}
for b = 0, BLOCK_COUNT - 1 do
    blockHash[b] = nil
end

local palette = {}
for p = 0, OBJ_PALETTE_COUNT - 1 do
    palette[p] = { hash = nil, everChangedOw = false, everChangedNon = false, everNonzero = false }
end

local allocatorPeak = 0
local oamMinFree = OAM_ENTRY_COUNT
local lastDispcntMode = nil
local lastReservedTileCount = nil
local lastReservedPaletteCount = nil

local samplesTaken = 0
local framesOw, framesNon = 0, 0
local distinctCb2 = {}
local battleSeen = false
local everInOverworld = false
local lastCallback2 = nil
local nonOverworldRunFrames = 0

local function isOverworld(cb2)
    return cb2 == CB2_OVERWORLD_ADDR or cb2 == CB2_OVERWORLD_ADDR + 1
        or cb2 == CB2_OVERWORLD_ARCHIPELAGO_ADDR or cb2 == CB2_OVERWORLD_ARCHIPELAGO_ADDR + 1
end

local function tileAddr(i)
    return OBJ_VRAM0_ADDR + i * TILE_SIZE_4BPP
end

-- Every byte-array read goes through here, so the small reads work on a core without read_bytes_as_array; only
-- the 32KB-a-frame tile scan needs the bulk API, and TIER gates that.
local function readBytes(addr, len)
    if type(memory.read_bytes_as_array) == "function" then
        return memory.read_bytes_as_array(addr, len)
    end
    local out = {}
    for i = 0, len - 1 do
        out[i + 1] = memory.read_u8(addr + i)
    end
    return out
end

-- A cheap change signature for a small region: hash_region when available, else a byte-array string.
local function regionSignature(addr, len)
    if type(memory.hash_region) == "function" then
        return memory.hash_region(addr, len)
    end
    return table.concat(readBytes(addr, len), ",")
end

local function tileNonzero(i)
    local bytes = readBytes(tileAddr(i), TILE_SIZE_4BPP)
    for _, b in ipairs(bytes) do
        if b ~= 0 then return true end
    end
    return false
end

local function readAllocatorBitmap()
    -- 128 bytes, one read.
    return readBytes(SSPRITETILEALLOCBITMAP_ADDR, 128)
end

local function bitmapBit(bitmap, tileIndex)
    local byteVal = bitmap[(tileIndex // 8) + 1] -- 1-indexed array
    return (byteVal >> (tileIndex % 8)) & 1
end

-- Startup full scan: baseline hashes and nonzero state for every tile and palette slot, so a tile already nonzero
-- at load is flagged; after this only changes are looked at.

local function initialScan(frame, ow, cb2)
    if TIER == "A" or TIER == "B" then
        for b = 0, BLOCK_COUNT - 1 do
            blockHash[b] = regionSignature(OBJ_VRAM0_ADDR + b * BLOCK_SIZE, BLOCK_SIZE)
        end
    end
    local allocBitmap = readAllocatorBitmap()
    for i = 0, TOTAL_OBJ_TILE_COUNT - 1 do
        local t = tile[i]
        if TIER == "A" or TIER == "B" then
            t.hash = regionSignature(tileAddr(i), TILE_SIZE_4BPP)
        end
        -- Safe at every tier: readBytes falls back to per-byte reads.
        local nz = tileNonzero(i)
        if nz then
            if ow then t.everNonzeroOw = true else t.everNonzeroNon = true end
        end
        if bitmapBit(allocBitmap, i) == 1 then
            t.everAllocated = true
        end
    end
    for p = 0, OBJ_PALETTE_COUNT - 1 do
        local ps = palette[p]
        ps.hash = regionSignature(OBJ_PLTT_ADDR + p * PALETTE_SIZE, PALETTE_SIZE)
        local bytes = readBytes(OBJ_PLTT_ADDR + p * PALETTE_SIZE, PALETTE_SIZE)
        for _, byteVal in ipairs(bytes) do
            if byteVal ~= 0 then ps.everNonzero = true break end
        end
    end
    logLine("Initial full scan complete at frame " .. frame .. ".")
end

local function sampleObjVram(frame, ow, cb2)
    local anyBlockChanged = false
    for b = 0, BLOCK_COUNT - 1 do
        local h = memory.hash_region(OBJ_VRAM0_ADDR + b * BLOCK_SIZE, BLOCK_SIZE)
        if h ~= blockHash[b] then
            blockHash[b] = h
            anyBlockChanged = true
            local allocBitmap = readAllocatorBitmap()
            local baseTile = b * TILES_PER_BLOCK
            for j = 0, TILES_PER_BLOCK - 1 do
                local i = baseTile + j
                local t = tile[i]
                local newHash
                if TIER == "A" or TIER == "B" then
                    newHash = memory.hash_region(tileAddr(i), TILE_SIZE_4BPP)
                else
                    newHash = nil -- Tier C never reaches here, see sampleObjVramTierC
                end
                if newHash ~= t.hash then
                    t.hash = newHash
                    t.changeCount = t.changeCount + 1
                    if not t.firstChangeFrame then
                        t.firstChangeFrame = frame
                        t.firstChangeCb2 = cb2
                    end
                    t.lastChangeFrame = frame
                    if ow then t.everChangedOw = true else t.everChangedNon = true end
                    if bitmapBit(allocBitmap, i) == 0 then
                        t.disagreement = true
                    end
                    if TIER == "A" then
                        local nz = tileNonzero(i)
                        if nz then
                            if ow then t.everNonzeroOw = true else t.everNonzeroNon = true end
                        end
                    end
                end
                if bitmapBit(allocBitmap, i) == 1 then
                    t.everAllocated = true
                end
            end
        end
    end
    return anyBlockChanged
end

-- Tier C, with no hash_region or read_bytes_as_array: 4 fixed offsets per tile on a stride, far weaker than an
-- exhaustive scan and marked so in every report.
local TIER_C_OFFSETS = { 0, 8, 16, 24 }
local tierCCursor = 0
local function sampleObjVramTierC(frame, ow, cb2)
    -- One tile per frame call, stride handled by the caller's DETAIL_INTERVAL_FRAMES.
    local i = tierCCursor % TOTAL_OBJ_TILE_COUNT
    tierCCursor = tierCCursor + 1
    local t = tile[i]
    local changed = false
    for _, off in ipairs(TIER_C_OFFSETS) do
        local b = memory.read_u8(tileAddr(i) + off)
        local key = "b" .. off
        if t[key] ~= nil and t[key] ~= b then
            changed = true
        end
        t[key] = b
        if b ~= 0 then
            if ow then t.everNonzeroOw = true else t.everNonzeroNon = true end
        end
    end
    if changed then
        t.changeCount = t.changeCount + 1
        if not t.firstChangeFrame then
            t.firstChangeFrame = frame
            t.firstChangeCb2 = cb2
        end
        t.lastChangeFrame = frame
        if ow then t.everChangedOw = true else t.everChangedNon = true end
    end
end

local function samplePalettes(ow)
    for p = 0, OBJ_PALETTE_COUNT - 1 do
        local ps = palette[p]
        local h = regionSignature(OBJ_PLTT_ADDR + p * PALETTE_SIZE, PALETTE_SIZE)
        if h ~= ps.hash then
            ps.hash = h
            if ow then ps.everChangedOw = true else ps.everChangedNon = true end
            local bytes = readBytes(OBJ_PLTT_ADDR + p * PALETTE_SIZE, PALETTE_SIZE)
            for _, byteVal in ipairs(bytes) do
                if byteVal ~= 0 then ps.everNonzero = true break end
            end
        end
    end
end

local function sampleOam()
    local bytes = readBytes(OAM_ADDR, OAM_ENTRY_COUNT * OAM_ENTRY_SIZE)
    local free = 0
    for e = 0, OAM_ENTRY_COUNT - 1 do
        local yByte = bytes[e * OAM_ENTRY_SIZE + 1] -- 1-indexed array, attr0 low byte
        if yByte >= DISPLAY_HEIGHT then
            free = free + 1
        end
    end
    if free < oamMinFree then
        oamMinFree = free
    end
end

-- Reports contiguous runs, not per-tile lines, to stay inside the console scrollback.

local function forEachRun(predicate, emit)
    local runStart = nil
    for i = 0, TOTAL_OBJ_TILE_COUNT - 1 do
        if predicate(i) then
            if not runStart then runStart = i end
        else
            if runStart then
                emit(runStart, i - 1)
                runStart = nil
            end
        end
    end
    if runStart then
        emit(runStart, TOTAL_OBJ_TILE_COUNT - 1)
    end
end

local function runLines(predicate)
    local lines = {}
    forEachRun(predicate, function(a, b)
        local count = b - a + 1
        table.insert(lines, string.format("  0x%03X-0x%03X   %4d tiles   %5d bytes",
            a, b, count, count * TILE_SIZE_4BPP))
    end)
    if #lines == 0 then
        table.insert(lines, "  (none)")
    end
    return lines
end

local function report(frame)
    local cb2Count = 0
    for _ in pairs(distinctCb2) do cb2Count = cb2Count + 1 end

    logLine(string.format("=== OBJ VRAM probe report @ frame %d (tier %s, domain System Bus) ===",
        frame, TIER))
    logLine(string.format(
        "coverage: sampled=%d  ow=%d  non-ow=%d  battleSeen=%s  distinct cb2=%d",
        samplesTaken, framesOw, framesNon, tostring(battleSeen), cb2Count))
    logLine(string.format("BG mode: %s   reservedTileCount: %s   reservedPaletteCount: %s",
        tostring(lastDispcntMode), tostring(lastReservedTileCount), tostring(lastReservedPaletteCount)))
    logLine(string.format("allocator peak: %d/%d tiles allocated   OAM min free slots this session: %d/%d",
        allocatorPeak, TOTAL_OBJ_TILE_COUNT, oamMinFree, OAM_ENTRY_COUNT))

    logLine("")
    logLine("NEVER touched (no nonzero, no change, never allocated, any context):")
    for _, l in ipairs(runLines(function(i)
        local t = tile[i]
        return not t.everNonzeroOw and not t.everNonzeroNon
            and not t.everChangedOw and not t.everChangedNon
            and not t.everAllocated
    end)) do logLine(l) end

    logLine("")
    logLine("Untouched in overworld ONLY (touched while not in overworld):")
    for _, l in ipairs(runLines(function(i)
        local t = tile[i]
        return not t.everNonzeroOw and not t.everChangedOw
            and (t.everNonzeroNon or t.everChangedNon)
    end)) do logLine(l) end

    logLine("")
    logLine("ALLOCATED but always blank (NOT free -- the game owns these):")
    for _, l in ipairs(runLines(function(i)
        local t = tile[i]
        return t.everAllocated and not t.everNonzeroOw and not t.everNonzeroNon
    end)) do logLine(l) end

    logLine("")
    logLine("*** DISAGREEMENT: changed while the allocator said free (unmanaged writer) ***")
    for _, l in ipairs(runLines(function(i) return tile[i].disagreement end)) do logLine(l) end

    logLine("")
    logLine("OBJ palette slots ever changed / ever nonzero:")
    for p = 0, OBJ_PALETTE_COUNT - 1 do
        local ps = palette[p]
        logLine(string.format("  slot %2d: changedOw=%s changedNon=%s nonzero=%s",
            p, tostring(ps.everChangedOw), tostring(ps.everChangedNon), tostring(ps.everNonzero)))
    end
    logLine("=== end report ===")
end

logLine("MeshGhost VRAM probe (Stage 1) running. This is a read-only DEV PROBE, not the shipped adapter.")
logLine("Run the full session checklist from the Stage 1 plan (walk, menus, battle, bike, surf, PC, Mart, Fly) before reading the report.")
logLine("Reports print automatically every ~10s and on script exit; nothing is written to the ROM or save.")

local frameCounter = 0
local initialCb2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
local initialOw = isOverworld(initialCb2)
initialScan(frameCounter, initialOw, initialCb2)

if type(event.onexit) == "function" then
    event.onexit(function()
        logLine("MeshGhost VRAM probe: script exiting, final report follows.")
        report(frameCounter)
        if logFile then
            logFile:close()
        end
    end, "vram_probe_final_report")
end

local function runFrame()
    frameCounter = frameCounter + 1

    local cb2 = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    local ow = isOverworld(cb2)
    if cb2 ~= lastCallback2 then
        distinctCb2[cb2] = true
        lastCallback2 = cb2
    end
    if ow then
        framesOw = framesOw + 1
        everInOverworld = true
        nonOverworldRunFrames = 0
    else
        framesNon = framesNon + 1
        -- Counted as battle only once the overworld has been seen, or the title screen would qualify; a sustained
        -- non-overworld callback2 is still only a heuristic (a long dialogue or a menu fires it too).
        if everInOverworld then
            nonOverworldRunFrames = nonOverworldRunFrames + 1
            if nonOverworldRunFrames > 300 then
                battleSeen = true
            end
        end
    end

    local dispcnt = memory.read_u16_le(REG_DISPCNT_ADDR)
    local mode = dispcnt & 0x7
    if mode ~= lastDispcntMode then
        logLine(string.format("frame %d: BG mode changed to %d%s", frameCounter, mode,
            mode >= 3 and string.format(" (BITMAP MODE -- OBJ tile 0 shifts to 0x%08X, tiles 0-511 unusable here)", OBJ_VRAM1_ADDR) or ""))
        lastDispcntMode = mode
    end

    local reservedTiles = memory.read_u16_le(GRESERVEDSPRITETILECOUNT_ADDR)
    if reservedTiles ~= lastReservedTileCount then
        logLine(string.format("frame %d: gReservedSpriteTileCount changed to %d", frameCounter, reservedTiles))
        lastReservedTileCount = reservedTiles
    end
    local reservedPalettes = memory.read_u8(GRESERVEDSPRITEPALETTECOUNT_ADDR)
    if reservedPalettes ~= lastReservedPaletteCount then
        logLine(string.format("frame %d: gReservedSpritePaletteCount changed to %d", frameCounter, reservedPalettes))
        lastReservedPaletteCount = reservedPalettes
    end

    if frameCounter % COARSE_INTERVAL_FRAMES == 0 then
        samplesTaken = samplesTaken + 1
        if TIER == "A" or TIER == "B" then
            sampleObjVram(frameCounter, ow, cb2)
        else
            sampleObjVramTierC(frameCounter, ow, cb2)
        end
        samplePalettes(ow)
        sampleOam()
        local allocBitmap = readAllocatorBitmap()
        local allocated = 0
        for i = 0, TOTAL_OBJ_TILE_COUNT - 1 do
            if bitmapBit(allocBitmap, i) == 1 then allocated = allocated + 1 end
        end
        if allocated > allocatorPeak then allocatorPeak = allocated end
    end

    if frameCounter % REPORT_INTERVAL_FRAMES == 0 then
        report(frameCounter)
    end
end

local lastFrameErrorLogged = 0
while true do
    local ok, err = pcall(runFrame)
    if not ok then
        if frameCounter - lastFrameErrorLogged > 300 then
            logLine("MeshGhost VRAM probe: frame error (continuing): " .. tostring(err))
            lastFrameErrorLogged = frameCounter
        end
    end
    emu.frameadvance()
end
