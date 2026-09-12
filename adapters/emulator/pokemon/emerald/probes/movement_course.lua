-- MeshGhost -- Emerald: drive a FIXED COURSE, so one gait can be compared against another.
-- DEV TOOL, d-pad only (plus B as the run modifier). Never presses A.
--
-- WHY. Walking and running were confirmed 1:1 against the player on 2026-09-13; the bikes were
-- then reported teleporting, sliding and facing the wrong way. The user's ask: *"make a probe where
-- you go in straight lines / squares, or a mix just to test/compare movement. we know walking &
-- running works 1:1 now for comparison"*. A fault that only appears on one gait needs the SAME
-- course on every gait, or the comparison is between two different journeys.
--
-- THE COURSE, one lap, and every leg ends on the POSITION rather than a frame count (a fixed count
-- cannot express "one tile" across gaits whose steps are 16, 8, 4 or 2 frames --
-- adapters/_template/probes.md, "A driven leg is MEASURED, not timed"):
--
--   1. straight out 4 tiles LEFT, stop        -- a long straight, the easiest thing to judge
--   2. straight back 4 tiles RIGHT, stop      -- the same ground in reverse: a turn-around
--   3. straight out 4 tiles UP, stop
--   4. straight back 4 tiles DOWN, stop
--   5. a 2x2 square, corners FLOWING          -- four turns with no stop to hide them
--
-- Each phase is announced to the console and the log, so a per-frame trace (the adapter's
-- MESHGHOST_EMERALD_MOVE_TRACE) can be cut into phases afterwards and one gait laid against
-- another. The stops matter as much as the movement: a fault at the END of motion showed up on
-- every gait this session, and a course with no stops in it would have hidden it.
--
-- GAIT COMES FROM THE STATE, NOT FROM HERE. Walking is the default; MESHGHOST_COURSE_RUN holds B;
-- a bike comes from the savestate the rig loads (slot 9 mach, slot 10 acro -- the user's, 2026-09-13),
-- because a bike is a mounted state this probe has no business toggling.
--
-- WHAT IT IS NOT: passive. Drop it from the loader's target file before judging anything by eye.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local SETTLE = 30          -- frames standing still at the end of a straight leg
local STUCK  = 150         -- a leg this long never moved: turn it round rather than lean on a wall

local function u32(a) local ok, v = pcall(memory.read_u32_le, a) return (ok and v) or 0 end
local function s16(a) local ok, v = pcall(memory.read_s16_le, a) return (ok and v) or 0 end

-- THE STRAIGHT IS LONG ON PURPOSE. The user, watching the acro bike: *"need to go a bit further in
-- 1 direction for the teleporting"* -- and a fault whose severity grows with the LENGTH of an action
-- is something that REPEATS or ACCUMULATES rather than a constant offset (Crystal's own rule:
-- *"1 tile looks good/perfect... 4-5+ tiles and it starts to look really jittery"*). Four tiles hid
-- it; ten gives it room to build. Both lengths are knobs so a suspicion about length is one edit.
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
