-- MeshGhost — Emerald: the frame rate while the player stands still, pressing nothing (dev tool). For comparing tiers:
-- a moving route leaves fixed-position synthetic peers behind, and the painted tier's cull then makes them nearly free.

local HOLD_FRAMES = 1800 -- samples, not seconds: a slow run is not a short run
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
-- The file only, one console line at the end: a console line is a GUI append that costs frames.
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
