-- MeshGhost — Emerald: hold still and report the frame rate. READ-ONLY, drives no input.
--
-- WHY THIS EXISTS ALONGSIDE fpsride.lua, which is the usual instrument.
-- `fpsride` walks a fixed route, and that is the right harness for "does the adapter cost the player
-- anything while they play". It is the WRONG harness for comparing two rendering tiers against each
-- other, and the reason is a trap this project walked into on 2026-08-21:
--
--   * the hardware-sprite probe positions its copies RELATIVE TO THE PLAYER, so they are on screen
--     for every frame of the route;
--   * synthetic peers from `meshghost-fakeadapter` orbit a FIXED map coordinate, so walking the
--     route leaves them behind, and the painted tier's own off-screen cull then makes them nearly
--     free.
--
-- The user spotted it from the screen before the numbers did -- *"the drawn ghosts are not following
-- when you go to the left. not accurate testing"* -- and the adapter's own status line had been
-- saying `drawn=0` mid-ride the whole time. A tier comparison run that way flatters whichever side
-- happens to still be visible.
--
-- So this probe removes movement from the comparison entirely: the player stands still, the peers
-- are centred on where the player is standing, and both tiers are measured with the same crowd
-- actually on screen for the whole window. Movement is a separate question, measured separately.
--
-- LOGS TO THE FILE, one console line at the end. `console.log` is a GUI append whose cost grows with
-- the window's backlog, and one line a second was measured at 7.4 fps on this very machine
-- (pitfalls.md, 2026-08-21). An instrument that costs more than the thing it measures is worse than
-- no instrument.
--
-- HOW TO RUN
--   Point the dev loader at whatever is being measured plus this file, and leave the player standing
--   still. It samples for HOLD_FRAMES and then writes its summary; it never presses a button, so a
--   run is reproducible without the player being in any particular place on the map.

local HOLD_FRAMES = 1800 -- 30s at 60fps, and longer in wall clock if the thing being measured is
                         -- slow -- which is the point: a slow run is not a short run.
local WARMUP = 60        -- the frames right after a loader swap are not representative

local function scriptDir()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end

-- A label the operator sets from outside, so a row says which condition produced it.
local LABEL = tostring(MESHGHOST_FPSHOLD_LABEL or "unlabelled")

local logPath = ("%s/fpshold_%s.log"):format(scriptDir(), os.date("%Y%m%d_%H%M%S"))
local logfile = io.open(logPath, "a")
local function log(msg)
    if logfile then logfile:write(msg, string.char(10)) logfile:flush() end
end

local n, samples, lowest, total = 0, 0, 999, 0
local done = false

local function tick()
    if done then return end
    n = n + 1
    if n <= WARMUP then return end
    local f = client.get_approx_framerate and client.get_approx_framerate() or -1
    if f > 0 then
        samples = samples + 1
        total = total + f
        if f < lowest then lowest = f end
    end
    if samples >= HOLD_FRAMES then
        done = true
        local line = string.format("HOLD [%s] -- %d samples: lowest %.1f, average %.1f",
            LABEL, samples, lowest, total / samples)
        log(line)
        console.log("fpshold: " .. line)
        console.log("fpshold: log " .. logPath)
    end
end

log(string.format("=== fpshold [%s]: standing still, %d frames ===", LABEL, HOLD_FRAMES))

MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function()
    if not done and samples > 0 then
        log(string.format("HOLD [%s] -- PARTIAL, %d samples: lowest %.1f, average %.1f",
            LABEL, samples, lowest, total / samples))
    end
    if logfile then logfile:close() logfile = nil end
end

if not MESHGHOST_DEV_LOADER then
    while true do
        tick()
        emu.frameadvance()
    end
end
