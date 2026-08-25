-- MeshGhost -- what maps CONNECT to this one, measured (DEV TOOL, never shipped)
--
-- WHY. Cross-map ghosts (user request, 2026-08-20: see peers across a route seam, still hide them
-- in houses) need three facts per neighbor: which map it is, the seam offset, and its dimensions.
-- The engine keeps all three -- seams are "connections" in the map header, and houses join by warp
-- instead, which is exactly the distinction wanted -- but the structs must be MEASURED before the
-- adapter trusts them (CLAUDE.md: no addresses from memory).
--
-- STRUCTS UNDER TEST (pokeemerald include/global.h, include/fieldmap.h -- field NAMES cited, the
-- layout is what this probe verifies):
--   MapHeader: mapLayout +0x00, events +0x04, mapScripts +0x08, connections +0x0C
--   MapConnections: count s32 +0x00, list ptr +0x04
--   MapConnection: direction u8 +0x00, offset s32 +0x04, mapGroup u8 +0x08, mapNum u8 +0x09,
--     stride 12 (alignment)
--   MapLayout: width s32 +0x00, height s32 +0x04
--   directions: 1 south, 2 north, 3 west, 4 east (5 dive, 6 emerge)
--
-- SELF-LOCATING gMapGroups, because neighbor dimensions need the neighbor's header and only that
-- table maps group:num -> header. gMapHeader (02037318) is a COPY of the current map's ROM header,
-- so: find the ROM original by matching its first 16 bytes, find the pointer TO it (inside the
-- group's header array), then the pointer to THAT array (inside gMapGroups). Each step verified by
-- reading back -- the same self-location idea as the Archipelago sprite-shift detection.
local GMAPHEADER = 0x02037318
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local ROM_BASE, ROM_END = 0x08000000, 0x09000000
local CHUNK = 0x20000                     -- 128KB per frame keeps the scan off the game's back

local function r8(a) return memory.read_u8(a) end
local function r32(a) return memory.read_u32_le(a) end
local function rs32(a) return memory.read_s32_le(a) end

local BSLASH = string.char(92)
local logPath = ("%s/connections.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."))
local logFile = io.open(logPath, "w")
local function say(s)
    console.log("connections: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

local DIRNAME = { [1] = "south", [2] = "north", [3] = "west", [4] = "east", [5] = "dive", [6] = "emerge" }

-- Chunked ROM scan for a 4-byte little-endian value, aligned. Resumes across frames.
local scan = { target = nil, at = ROM_BASE, hits = {}, done = true }
local function startScan(value)
    scan.target = value scan.at = ROM_BASE scan.hits = {} scan.done = false
end
local function stepScan()
    if scan.done then return true end
    local b = memory.read_bytes_as_array(scan.at, CHUNK)
    local t = scan.target
    local b0 = t % 256
    local b1 = math.floor(t / 256) % 256
    local b2 = math.floor(t / 65536) % 256
    local b3 = math.floor(t / 16777216) % 256
    for i = 1, CHUNK - 3, 4 do
        if b[i] == b0 and b[i + 1] == b1 and b[i + 2] == b2 and b[i + 3] == b3 then
            scan.hits[#scan.hits + 1] = scan.at + i - 1
        end
    end
    scan.at = scan.at + CHUNK
    if scan.at >= ROM_END then scan.done = true end
    return scan.done
end

local phase, romHeader, groupArray, mapGroupsAt = "dump", nil, nil, nil
local lastMapKey = nil

local function dumpConnections()
    local sb1 = r32(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return false end
    local grp, num = r8(sb1 + 0x04), r8(sb1 + 0x05)
    local key = grp .. ":" .. num
    if key == lastMapKey then return false end
    lastMapKey = key
    local connPtr = r32(GMAPHEADER + 0x0c)
    say(string.format("=== map %s: connections ptr %08X", key, connPtr))
    if connPtr < 0x08000000 or connPtr >= ROM_END then
        say("no connections (a house should look exactly like this)")
        return true
    end
    local count = rs32(connPtr)
    local list = r32(connPtr + 4)
    say(string.format("count=%d list=%08X", count, list))
    if count < 0 or count > 8 or list < 0x08000000 then
        say("IMPLAUSIBLE -- the struct layout assumption is wrong, stop here")
        return true
    end
    for i = 0, count - 1 do
        local c = list + i * 12
        local dir, off = r8(c), rs32(c + 4)
        local cg, cn = r8(c + 8), r8(c + 9)
        local dims = ""
        if mapGroupsAt then
            local hdr = r32(r32(mapGroupsAt + cg * 4) + cn * 4)
            if hdr >= 0x08000000 and hdr < ROM_END then
                local lay = r32(hdr)
                dims = string.format("  neighbor %dx%d", rs32(lay), rs32(lay + 4))
            end
        end
        say(string.format("  [%d] %s offset=%d -> map %d:%d%s", i, DIRNAME[dir] or dir, off, cg, cn, dims))
    end
    return true
end

local function tick()
    if phase == "dump" then
        if dumpConnections() ~= false then
            if mapGroupsAt then
                phase = "watch"
            else
                phase = "find_header"
                startScan(r32(GMAPHEADER))
                say("locating gMapGroups: scanning for this header in ROM ...")
            end
        end
    elseif phase == "find_header" then
        if stepScan() then
            local matches = {}
            for _, a in ipairs(scan.hits) do
                local ok = true
                for k = 0, 12, 4 do
                    if r32(a + k) ~= r32(GMAPHEADER + k) then ok = false break end
                end
                if ok then matches[#matches + 1] = a end
            end
            say(string.format("header candidates: %d (of %d raw hits)", #matches, #scan.hits))
            if #matches ~= 1 then
                say("need exactly one -- move one map and reload to retry")
                phase = "watch"
                return
            end
            romHeader = matches[1]
            say(string.format("ROM header at %08X", romHeader))
            startScan(romHeader)
            phase = "find_group"
        end
    elseif phase == "find_group" then
        if stepScan() then
            local sb1 = r32(GSAVEBLOCK1PTR_ADDR)
            local num = r8(sb1 + 0x05)
            local found = nil
            for _, a in ipairs(scan.hits) do
                local base = a - num * 4
                if r32(base + num * 4) == romHeader then found = base break end
            end
            if not found then say("no group array found") phase = "watch" return end
            groupArray = found
            say(string.format("group header array at %08X", groupArray))
            startScan(groupArray)
            phase = "find_groups"
        end
    elseif phase == "find_groups" then
        if stepScan() then
            local sb1 = r32(GSAVEBLOCK1PTR_ADDR)
            local grp = r8(sb1 + 0x04)
            for _, a in ipairs(scan.hits) do
                local base = a - grp * 4
                if r32(base + grp * 4) == groupArray then mapGroupsAt = base break end
            end
            say(mapGroupsAt and string.format("gMapGroups at %08X -- verify by crossing the seam", mapGroupsAt)
                or "gMapGroups not found")
            lastMapKey = nil   -- re-dump, this time with neighbor dimensions
            phase = "dump"
        end
    elseif phase == "watch" then
        -- Cross a seam and the new map dumps itself; a house should print "no connections".
        dumpConnections()
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
