-- MeshGhost -- Pokémon Emerald: walk the player in a square, forever. DEV TOOL, d-pad only.
--
-- PORTED FROM CRYSTAL'S `probes/square_drive.lua`, which was written for the user's own test case
-- and carries the reasoning this one inherits: one lap exercises all four directions, all four
-- turns, and the corner case where a step is immediately followed by a turn. Cross-checking the
-- sibling adapter before writing a probe is the standing rule for two games in one series
-- (adapters/_template/probes.md).
--
-- THE ONE THING CHANGED IN THE PORT, and it is not a detail: **a leg ends when the TILE changes,
-- not after N frames.** Crystal holds 18 frames for an 8-frame step; Emerald's walking step is 16
-- and its running step is 8, so any fixed count is either short (a leg that never completes) or
-- long (a leg that leaks into the next step and drifts the square off its ground). Measuring the
-- position instead makes the same script correct at every gait, which is the point when the thing
-- being judged is how a ghost moves at each of them. Today's lesson, the expensive way:
-- adapters/_template/probes.md, "A driven leg is MEASURED, not timed".
--
-- WHAT IT IS NOT: a passive instrument. It drives input, so drop it from the loader's target file
-- before judging anything by eye. It never presses A, so it cannot talk to anyone, open a menu or
-- advance a script; it presses B only as the RUN modifier below, held with a direction, which does
-- nothing on its own in the overworld. It knows nothing about walls: point it at open ground.
--
-- OPTIONS (globals, set by a script listed ahead of this one):
--   MESHGHOST_SQUARE_SIDE   tiles per side, default 4 (the user's ask, 2026-09-12)
--   MESHGHOST_SQUARE_DIRS   the order of sides, default Up -> Left -> Down -> Right
--   MESHGHOST_SQUARE_PAUSE  true to stand still without unloading
--   MESHGHOST_SQUARE_RUN    true to hold B throughout, so every side is RUN rather than walked --
--                           a different step duration (8 frames, not 16) and therefore a different
--                           test: the glide's speed comes from the peer's own rate, so a fault
--                           that hides at walking pace need not hide at running pace
--   MESHGHOST_SQUARE_STOPS  true to stop at corners; default is a FLOWING lap, because a stop at
--                           every corner makes the ghost show a real catch-up and a real slip
--                           there, and those are indistinguishable from renderer faults by eye
--                           (Crystal's own note, 2026-08-23). Continuous motion is judged flowing.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local SIDE = tonumber(MESHGHOST_SQUARE_SIDE) or 4
local DIRECTIONS = MESHGHOST_SQUARE_DIRS or { "Up", "Left", "Down", "Right" }
local STUCK = 120   -- a leg this long never moved: a wall, so turn the corner anyway

local function u32(a) local ok, v = pcall(memory.read_u32_le, a) return (ok and v) or 0 end
local function s16(a) local ok, v = pcall(memory.read_s16_le, a) return (ok and v) or 0 end

local logfile
do
    local dir = "."
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    logfile = io.open(string.format("%s/square_drive_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
    -- Buffered, never flushed per line: a per-line disk write on the emulator's thread was measured
    -- at 63-83ms -- four or five frames, every time. A probe that stalls the game changes what it
    -- measures.
    if logfile then pcall(function() logfile:setvbuf("full", 8192) end) end
end
local consoleLines, flushEvery = 0, 0
local function log(msg)
    consoleLines = consoleLines + 1
    -- The console is the expensive half (one line a second cost 7.4fps once), so it gets a glance
    -- and the file gets the record.
    if consoleLines <= 3 or consoleLines % 20 == 0 then pcall(console.log, msg) end
    if logfile then
        logfile:write(msg, "\n")
        flushEvery = flushEvery + 1
        if flushEvery >= 20 then flushEvery = 0 pcall(function() logfile:flush() end) end
    end
end

log(string.format("=== MeshGhost Emerald square driver === %d tiles a side, %s, corners %s, %s",
    SIDE, table.concat(DIRECTIONS, " -> "), MESHGHOST_SQUARE_STOPS and "STOPPING" or "flowing",
    MESHGHOST_SQUARE_RUN and "RUNNING (B held)" or "walking"))

local dirIndex, tilesDone, heldFor, laps, frames, pauseFor = 1, 0, 0, 0, 0, 0
local startX, startY

MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    if MESHGHOST_SQUARE_PAUSE then return end
    if pauseFor > 0 then pauseFor = pauseFor - 1 return end

    -- The save block is a POINTER and it moves: read it every frame rather than caching it.
    local sb1 = u32(GSAVEBLOCK1PTR_ADDR)
    if sb1 < 0x02000000 then return end
    local x, y = s16(sb1 + 0x00), s16(sb1 + 0x02)
    if startX == nil then startX, startY = x, y end

    local want = DIRECTIONS[dirIndex]
    -- With AND without the controller index: BizHawk's per-core controller naming differs, and a
    -- set naming a controller the core does not have is ignored silently -- which reads exactly
    -- like "the script is running and the character will not move".
    --
    -- B IS THE RUN BUTTON (with the Running Shoes), and it is held with the direction rather than
    -- tapped. It opens nothing in the overworld on its own, so this cannot wander into a menu.
    local press = { [want] = true }
    if MESHGHOST_SQUARE_RUN then press.B = true end
    pcall(joypad.set, press)
    pcall(joypad.set, press, 1)
    heldFor = heldFor + 1

    local moved = (x ~= startX or y ~= startY)
    if not moved and heldFor < STUCK then return end
    if not moved then
        log(string.format("  side %s blocked after %d frames at %d,%d -- turning early",
            want, heldFor, x, y))
    end

    heldFor, startX, startY = 0, x, y
    tilesDone = tilesDone + 1
    if tilesDone < SIDE then return end

    tilesDone, dirIndex = 0, dirIndex + 1
    if dirIndex <= #DIRECTIONS then
        if MESHGHOST_SQUARE_STOPS then
            pauseFor = 120
            log(string.format("  corner after side %d -- stopping 2s", dirIndex - 1))
        end
        return
    end

    dirIndex, laps = 1, laps + 1
    log(string.format("  lap %d complete at %d,%d", laps, x, y))
    if MESHGHOST_SQUARE_STOPS then pauseFor = 420 end
end

MESHGHOST_DEV_UNLOAD = function()
    if logfile then
        pcall(function() logfile:flush() end)
        logfile:close()
        logfile = nil
    end
end

if not MESHGHOST_DEV_LOADER then
    while true do
        MESHGHOST_DEV_TICK()
        emu.frameadvance()
    end
end
