-- Walk ONE tile back and forth across an EAST/WEST seam, forever. DEV TOOL, presses the d-pad only.
--
-- The user's own repro, 2026-09-12: *"emerald2, move 1 tile left, then 1tile right -- to go back/
-- forth between a route and town seam"*. Pacing a crossing is what makes a seam fault happen over
-- and over instead of once, and Crystal's own copy of this file (probes/seam_shuttle.lua there)
-- records why that matters: a build that lands mid-load is common while pacing and rare on a
-- single crossing.
--
-- PORTED FROM CRYSTAL'S, deliberately -- same probe, different addresses. Cross-checking the
-- sibling adapter before writing anything is the standing rule for two games in one series.
--
-- WHAT IT IS NOT: a passive instrument. It drives input, so it is a suspect in anything seen while
-- it is loaded -- drop it from the loader's target file before judging a crossing by eye.
--
-- A LEG IS ONE TILE, MEASURED, NOT TIMED. The first version held each direction for a fixed 20
-- frames, which is longer than Emerald's 16-frame step: every leg leaked four frames into the next
-- step, so the walk never stopped and drifted further left each lap -- the user, watching it:
-- *"you are walking to fast/to far left"*. A fixed frame count cannot express "one tile" in a game
-- whose step length depends on what the player is riding and whether the tile is rough. So the leg
-- ends when the POSITION says it did -- x changed, or the map did -- and only then.
--
-- AND THEN IT STOPS, for SETTLE frames. The stop is not politeness: the adapter's anchor only
-- re-calibrates while the player has been still for four frames (`tiering.tileStill`), so a shuttle
-- that never stands still is measuring a state the player never sits in.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c

local function u32(a) local ok, v = pcall(memory.read_u32_le, a) return (ok and v) or 0 end
local function u8(a) local ok, v = pcall(memory.read_u8, a) return (ok and v) or 0 end
local function s16(a) local ok, v = pcall(memory.read_s16_le, a) return (ok and v) or 0 end

local SETTLE = 24          -- frames standing still between legs, comfortably past the anchor's 4
local STUCK  = 90          -- a leg this long never moved: something is in the way, so turn around

-- A LEG ENDS WHEN THE MAP CHANGES, and that one rule both finds the seam and paces it.
--
-- Two earlier versions got this wrong in ways worth keeping. The first alternated a fixed
-- Left/Right pair, so it shuttled between whatever two tiles it happened to start on -- one tile
-- west of the boundary after a reload, which paces an ordinary step while claiming to test a seam.
-- The second chose the direction from "am I on the map I started on", which wanders the moment the
-- player is not already adjacent to the boundary: measured walking 0:10 tiles 0,1,2,3 eastward
-- while the seam sat behind it, and the user, watching: *"why is it just walking right?"*.
--
-- So: press one way until the MAP changes, then settle and press the other way. Adjacent to the
-- boundary that is exactly one tile per leg, which is the repro. Further away the first leg simply
-- walks until it crosses -- the seeking and the pacing are the same behaviour, so there is no mode
-- to get wrong. The allowance below is what keeps a wrong first guess from walking to the horizon.
local ALLOW0 = 40          -- frames a leg may run before admitting this direction found no seam
local ALLOW_MAX = 400
local allow, found = ALLOW0, false
local dir, phase, held, startArea, lastArea = "Left", "press", 0, nil, nil

MESHGHOST_DEV_TICK = function()
    -- THE SAVE BLOCK IS A POINTER, and it moves: read it every frame rather than caching it, the
    -- same way the adapter does. A stale pointer reads a plausible number from nowhere.
    local sb1 = u32(GSAVEBLOCK1PTR_ADDR)
    if sb1 < 0x02000000 then return end
    local x, area = s16(sb1 + 0x00), u8(sb1 + 0x04) .. ":" .. u8(sb1 + 0x05)
    if area ~= lastArea then
        pcall(function()
            console.log(string.format("seam_shuttle: now on %s at %d,%d (was pressing %s)",
                area, x, s16(sb1 + 0x02), dir))
        end)
        lastArea = area
    end

    if phase == "press" then
        if startArea == nil then startArea = area end
        pcall(joypad.set, { [dir] = true })
        pcall(joypad.set, { [dir] = true }, 1)
        held = held + 1
        -- THE MAP, not the tile. A leg that ends on "x changed" stops one tile short of the seam
        -- and then paces two ordinary tiles forever; ending on the crossing itself is what keeps
        -- the probe on the thing it is named after.
        if area ~= startArea then
            -- Found it: from here every leg is one crossing, so the allowance goes back to a length
            -- that only a wall can reach.
            allow, found = STUCK, true
            phase, held = "settle", 0
        elseif held >= allow then
            -- No crossing this way. Turn around and look further, doubling the reach each time so a
            -- seam ten tiles off is found in a few legs instead of never -- and cap it, because an
            -- unbounded search walks the player across the region.
            if not found then allow = math.min(allow * 2, ALLOW_MAX) end
            phase, held = "settle", 0
        end
    else
        held = held + 1
        if held >= SETTLE then
            -- ALWAYS the other way. Having just crossed, this crosses back; having just failed to
            -- cross, this searches the opposite side. One rule, both jobs.
            dir = (dir == "Left") and "Right" or "Left"
            phase, held, startArea = "press", 0, nil
        end
    end
end
