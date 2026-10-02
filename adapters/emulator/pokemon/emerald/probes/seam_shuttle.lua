-- MeshGhost — Emerald: back and forth across an east/west seam forever, d-pad only (dev tool); drop it before judging.
-- After each leg it stands still SETTLE frames: the adapter's anchor re-calibrates only after four still frames.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c

local function u32(a) local ok, v = pcall(memory.read_u32_le, a) return (ok and v) or 0 end
local function u8(a) local ok, v = pcall(memory.read_u8, a) return (ok and v) or 0 end
local function s16(a) local ok, v = pcall(memory.read_s16_le, a) return (ok and v) or 0 end

local SETTLE = 24          -- frames standing still between legs, comfortably past the anchor's 4
local STUCK  = 90          -- a leg this long never moved: something is in the way, so turn around

-- A leg ends when the map changes, which both finds the seam and paces it: next to the boundary that is one tile a
-- leg, and further away the first leg walks until it crosses, within an allowance that keeps a wrong guess near.
local ALLOW0 = 40          -- frames a leg may run before admitting this direction found no seam
local ALLOW_MAX = 400
local allow, found = ALLOW0, false
local dir, phase, held, startArea, lastArea = "Left", "press", 0, nil, nil

MESHGHOST_DEV_TICK = function()
    -- The save block pointer moves: read it every frame, never cached.
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
        -- The map, not the tile: ending on x stops one tile short of the seam and paces two ordinary tiles.
        if area ~= startArea then
            -- Found: every leg is one crossing now, so only a wall reaches the allowance.
            allow, found = STUCK, true
            phase, held = "settle", 0
        elseif held >= allow then
            -- No crossing this way: turn round and double the reach, capped so the search cannot cross the region.
            if not found then allow = math.min(allow * 2, ALLOW_MAX) end
            phase, held = "settle", 0
        end
    else
        held = held + 1
        if held >= SETTLE then
            -- Always the other way: back across after a crossing, the far side after a failed search.
            dir = (dir == "Left") and "Right" or "Left"
            phase, held, startArea = "press", 0, nil
        end
    end
end
