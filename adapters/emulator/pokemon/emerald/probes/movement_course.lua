-- Drives a fixed course so one gait can be laid against another (dev tool, d-pad plus B to run, never A): long
-- straights out and back on each axis with a stop after each, then a square with flowing corners. Every leg ends on
-- the position, not a frame count, since a step is 16, 8, 4 or 2 frames by gait. Each leg is logged, so a
-- per-frame trace (MESHGHOST_EMERALD_MOVE_TRACE) can be cut into phases; the stops matter, as faults at the end of
-- motion show there. Walking is the default, MESHGHOST_COURSE_RUN holds B, and a bike comes from the savestate
-- loaded first. It drives input, so drop it from the loader before judging anything by eye.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local SETTLE = 30          -- frames standing still at the end of a straight leg
local STUCK  = 150         -- a leg this long never moved: turn it round rather than lean on a wall

local function u32(a) local ok, v = pcall(memory.read_u32_le, a) return (ok and v) or 0 end
local function s16(a) local ok, v = pcall(memory.read_s16_le, a) return (ok and v) or 0 end

-- Long straights: a fault that grows with an action's length repeats or accumulates. Both lengths are knobs.
local STRAIGHT = tonumber(MESHGHOST_COURSE_STRAIGHT) or 10
local SQUARE = tonumber(MESHGHOST_COURSE_SQUARE) or 2

-- { direction, tiles, stop-after }  -- the whole course in one table, so reading it is reading it
local COURSE = {
    { "Left",  STRAIGHT, true  },
    { "Right", STRAIGHT, true  },
    { "Up",    STRAIGHT, true  },
    { "Down",  STRAIGHT, true  },
    { "Up",    SQUARE,   false },   -- the square: four turns taken in stride
    { "Left",  SQUARE,   false },
    { "Down",  SQUARE,   false },
    { "Right", SQUARE,   true  },
}

local logfile
do
    local dir = "."
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    logfile = io.open(string.format("%s/movement_course_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
    if logfile then pcall(function() logfile:setvbuf("full", 4096) end) end
end
local lines = 0
local function log(msg)
    lines = lines + 1
    if lines <= 4 or lines % 10 == 0 then pcall(console.log, msg) end
    if logfile then
        logfile:write(msg, "\n")
        pcall(function() logfile:flush() end)   -- a phase line a second at most; the cost is nil
    end
end

log(string.format("=== movement course === %s, %d legs, run=%s",
    os.date("%H:%M:%S"), #COURSE, tostring(MESHGHOST_COURSE_RUN and true or false)))

local leg, tilesDone, held, phase, laps = 1, 0, 0, "press", 0
local startX, startY

MESHGHOST_DEV_TICK = function()
    local sb1 = u32(GSAVEBLOCK1PTR_ADDR)
    if sb1 < 0x02000000 then return end
    local x, y = s16(sb1 + 0x00), s16(sb1 + 0x02)

    if phase == "settle" then
        held = held + 1
        if held >= SETTLE then
            held, phase, startX, startY = 0, "press", nil, nil
        end
        return
    end

    local dir, tiles, stopAfter = COURSE[leg][1], COURSE[leg][2], COURSE[leg][3]
    if startX == nil then
        startX, startY = x, y
        if tilesDone == 0 then
            log(string.format("leg %d: %s x%d at %d,%d", leg, dir, tiles, x, y))
        end
    end

    local press = { [dir] = true }
    if MESHGHOST_COURSE_RUN then press.B = true end
    pcall(joypad.set, press)
    pcall(joypad.set, press, 1)
    held = held + 1

    local moved = (x ~= startX or y ~= startY)
    if not moved and held < STUCK then return end
    if not moved then log(string.format("  leg %d BLOCKED at %d,%d after %d frames", leg, x, y, held)) end

    held, startX, startY = 0, nil, nil
    tilesDone = tilesDone + 1
    if tilesDone < tiles then return end

    tilesDone = 0
    if stopAfter then phase = "settle" end
    leg = leg + 1
    if leg > #COURSE then
        leg, laps = 1, laps + 1
        log(string.format("=== lap %d complete at %d,%d ===", laps, x, y))
    end
end

MESHGHOST_DEV_UNLOAD = function()
    if logfile then
        pcall(function() logfile:flush() end)
        logfile:close()
        logfile = nil
    end
end
