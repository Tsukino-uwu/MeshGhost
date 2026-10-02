-- spans_reuse.lua -- does Emerald's reusing reflectiveSpans produce exactly what the allocating path produces?
--
-- Run: lua5.4 adapters/emulator/tests/spans_reuse.lua   (from the repo root)
--
-- Reuse cannot raise an error, only a wrong answer: a stale row, or a leftover span from a longer previous row, both
-- wrong pixels on screen. The shipped function is lifted from the adapter by text; its dependencies are stubbed with
-- a pattern giving several spans per row and a changing span count between calls, the case the trim exists for.

local path = "adapters/emulator/pokemon/emerald/meshghost_emerald.lua"
local src = assert(io.open(path, "rb")):read("a")

local startAt = src:find("genderFrames.newSpanScratch = function", 1, true)
assert(startAt, "newSpanScratch not found -- the function was renamed and this test is testing nothing")
local endAt = src:find("\ngenderFrames.reflectPalFor = function", startAt, true)
assert(endAt, "could not find the end of reflectiveSpans")
local chunk = src:sub(startAt, endAt)

local TILE = 16
local genderFrames = {}
-- A readable map: an unreadable one returns before any span is built.
genderFrames.mapReadable = function() return true end
-- Only the map's identity (the decoded masks are dropped when it changes), so a constant is one map.
genderFrames.mapLayoutPtr = function() return 0x083EA284 end
-- A base that is not tile-aligned, so the in-tile row arithmetic is exercised.
genderFrames.gridBase = function() return 3, 5 end
genderFrames.metatileAt = function(gx, gy) return (gx * 31 + gy * 17) % 7 end

-- Per-row bitmasks varying with the metatile id and the row, so different calls produce different span counts.
local maskCache = {}
genderFrames.coverMask = function(id, who)
    local key = id .. ":" .. tostring(who)
    if maskCache[key] == nil then
        if id == 0 then
            maskCache[key] = true                       -- covers everywhere
        elseif id == 1 then
            maskCache[key] = false                      -- undecodable
        else
            local t = {}
            for row = 0, 15 do
                local bits = 0
                for bx = 0, 15 do
                    local open = ((bx + row + id) % 5) < 2
                    if not open then bits = bits | (1 << bx) end
                end
                t[row] = bits
            end
            maskCache[key] = t
        end
    end
    return maskCache[key]
end

local env = setmetatable({ genderFrames = genderFrames, TILE = TILE,
    r32 = function() return 0x02037318 end }, { __index = _G })
local fn = assert(load(chunk, "@reflectiveSpans", "t", env))
fn()

local function snapshot(spans)
    local rows = {}
    for py, list in pairs(spans) do rows[#rows + 1] = py end
    table.sort(rows)
    local out = {}
    for _, py in ipairs(rows) do
        local parts = {}
        for _, sp in ipairs(spans[py]) do
            parts[#parts + 1] = sp[1] .. "-" .. sp[2]
        end
        out[#out + 1] = py .. ":" .. table.concat(parts, ",")
    end
    return table.concat(out, "|")
end

-- The real sites' call shapes, ordered so a later call is shorter than an earlier one (the trim case).
local CASES = {
    { 10, 20, 16, 32, "sprite" },
    { 27, 44, 32, 48, "reflection" },
    { 5, 9, 16, 8, "sprite" },      -- much shorter than the one before it
    { 61, 70, 48, 32, "reflection" },
    { 10, 20, 16, 32, "sprite" },   -- back to the first, after the others
}

local sc = genderFrames.newSpanScratch()
local failures = 0
for i, c in ipairs(CASES) do
    local fresh = snapshot(genderFrames.reflectiveSpans(c[1], c[2], c[3], c[4], c[5]))
    local reused = snapshot(genderFrames.reflectiveSpans(c[1], c[2], c[3], c[4], c[5], sc))
    if fresh ~= reused then
        failures = failures + 1
        print(string.format("FAIL case %d (%d,%d %dx%d %s)", i, c[1], c[2], c[3], c[4], c[5]))
        print("  allocating: " .. fresh)
        print("  reusing   : " .. reused)
    end
end

local first = snapshot(genderFrames.reflectiveSpans(10, 20, 16, 32, "sprite", sc))
for _ = 1, 20 do
    local again = snapshot(genderFrames.reflectiveSpans(10, 20, 16, 32, "sprite", sc))
    if again ~= first then
        failures = failures + 1
        print("FAIL: repeated identical queries through one scratch drifted")
        break
    end
end

genderFrames.reflectiveSpans(10, 200, 16, 40, "sprite", sc)
local short = genderFrames.reflectiveSpans(10, 200, 16, 4, "sprite", sc)
local n = 0
for _ in pairs(short) do n = n + 1 end
if n ~= 4 then
    failures = failures + 1
    print(string.format("FAIL: a 4-row query returned %d rows -- a previous call's rows survived", n))
end

if failures > 0 then
    print(string.format("\n%d FAILURE(S)", failures))
    os.exit(1)
end
print("OK: reusing matches allocating on every case, repeats are stable, and stale rows are gone")
