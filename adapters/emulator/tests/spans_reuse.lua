-- spans_reuse.lua -- does Emerald's REUSING reflectiveSpans produce exactly what the allocating
-- path produces?
--
-- Run: lua5.4 adapters/emulator/tests/spans_reuse.lua   (from the repo root)
--
-- Does the REUSING path produce exactly what the allocating path produces?
--
-- That is the whole risk in review I36: reuse cannot raise an error, it can only produce a
-- slightly wrong answer -- a stale row a consumer reads as real, or a leftover span from a longer
-- previous row that gets painted. Both are wrong pixels on screen, which is not something the
-- agent side can see, so the equivalence has to be checked here instead.
--
-- The shipped function is lifted out of the adapter by text rather than copied, so this tests the
-- real one. Everything it depends on (the grid base, the metatile lookup, the cover masks) is
-- stubbed with a deterministic pattern that produces MULTIPLE spans per row and CHANGING span
-- counts between calls, which is the case the trim exists for.

local path = "adapters/emulator/pokemon/emerald/meshghost_emerald.lua"
local src = assert(io.open(path, "rb")):read("a")

local startAt = src:find("genderFrames.newSpanScratch = function", 1, true)
assert(startAt, "newSpanScratch not found -- the function was renamed and this test is testing nothing")
local endAt = src:find("\n-- DOES THIS GHOST REFLECT", startAt, true)
assert(endAt, "could not find the end of reflectiveSpans")
local chunk = src:sub(startAt, endAt)

local TILE = 16
local genderFrames = {}
-- A base that is not tile-aligned, so the in-tile row arithmetic is actually exercised.
genderFrames.gridBase = function() return 3, 5 end
genderFrames.metatileAt = function(gx, gy) return (gx * 31 + gy * 17) % 7 end

-- coverMask returns a per-row bitmask table. The pattern deliberately varies with the metatile id
-- AND the row, so different calls produce different numbers of spans.
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
                -- Alternating open/closed runs, shifted per id and row: several spans per row.
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

-- r32 reads the live map layout pointer, which the function uses only to drop its decoded-mask
-- cache when the map changes. A constant here means "the map never changed", which is the case
-- being tested.
local env = setmetatable({ genderFrames = genderFrames, TILE = TILE,
    r32 = function() return 0x02037318 end }, { __index = _G })
local fn = assert(load(chunk, "@reflectiveSpans", "t", env))
fn()

local function snapshot(spans)
    -- A stable, comparable text form: every row, every span, in order.
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

-- The call shapes the real sites use: different widths, heights and origins, in an order that
-- makes a later call SHORTER than an earlier one (the trim case).
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

-- And the same scratch used repeatedly for the SAME query must stay stable.
local first = snapshot(genderFrames.reflectiveSpans(10, 20, 16, 32, "sprite", sc))
for _ = 1, 20 do
    local again = snapshot(genderFrames.reflectiveSpans(10, 20, 16, 32, "sprite", sc))
    if again ~= first then
        failures = failures + 1
        print("FAIL: repeated identical queries through one scratch drifted")
        break
    end
end

-- A row the new call does not cover must be GONE, not left over from the previous call.
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
