-- MeshGhost — Pokémon Emerald: walks the player in a square, forever (dev tool, drives the pad, never shipped).
-- A side ends when the tile changes, never after a frame count; point it at open ground, never load it beside another
-- probe that presses buttons, and drop it before judging by eye. Globals, set by a script loaded first:
-- MESHGHOST_SQUARE_SIDE (tiles, default 4), _DIRS (side order), _PAUSE, _RUN (holds B) and _STOPS (stops at corners).
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
    if logfile then pcall(function() logfile:setvbuf("full", 8192) end) end
end
local consoleLines, flushEvery = 0, 0
local function log(msg)
    consoleLines = consoleLines + 1
    -- The console costs frames, so it gets a glance and the file the record.
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

    -- The save block pointer moves: read it every frame, never cache it.
    local sb1 = u32(GSAVEBLOCK1PTR_ADDR)
    if sb1 < 0x02000000 then return end
    local x, y = s16(sb1 + 0x00), s16(sb1 + 0x02)
    if startX == nil then startX, startY = x, y end

    local want = DIRECTIONS[dirIndex]
    -- Both forms: controller naming differs per core, and a set naming a controller the core lacks is ignored.
    -- B, the run button, is only ever held with a direction.
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
