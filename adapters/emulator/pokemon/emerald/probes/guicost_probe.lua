-- MeshGhost — Pokémon Emerald: what a gui.* call costs, with no adapter logic (dev tool, draws, never shipped).
-- Each frame it times CALLS bare loop passes, CALLS drawLine runs and CALLS drawPixel calls, and logs the cost per
-- call every WINDOW frames. Run it with the adapter unloaded, and never leave it loaded: it draws over the top-left
-- 8 rows. os.clock times this Lua only, not the emulator's frame pacing.

local CALLS = 8000        -- what 64 painted peers issue
local WINDOW = 300        -- matching the adapter's profiler
local RUN_LEN = 2         -- the measured average is 1.77 opaque px per run

local frames, accLine, accPixel, accNone = 0, 0, 0, 0

local function logPath()
    local info = debug.getinfo(1, "S")
    local dir = "."
    if info and info.source and info.source:sub(1, 1) == "@" then
        dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return dir .. "/guicost_probe.log"
end

local function say(line)
    console.log(line)
    local f = io.open(logPath(), "a")
    if f then f:write(line, "\n") f:close() end
end

local function tick()
    frames = frames + 1

    -- 1. The control: the loop with no gui call in it, so loop overhead is not charged to gui.
    local t0 = os.clock()
    local sink = 0
    for i = 1, CALLS do
        local x = i % 200
        local y = i % 8
        sink = sink + x + y
    end
    accNone = accNone + (os.clock() - t0)

    -- 2. Multi-pixel runs, the adapter's drawLine path.
    t0 = os.clock()
    for i = 1, CALLS do
        local x = i % 200
        local y = i % 8
        gui.drawLine(x, y, x + RUN_LEN - 1, y, 0xFF202020)
    end
    accLine = accLine + (os.clock() - t0)

    -- 3. Single pixels, the path a length-1 run takes.
    t0 = os.clock()
    for i = 1, CALLS do
        local x = i % 200
        local y = i % 8
        gui.drawPixel(x, y, 0xFF202020)
    end
    accPixel = accPixel + (os.clock() - t0)

    if frames >= WINDOW then
        say(string.format(
            "GUICOST (%d calls/frame, %d frames): loop-only %.2f ms | drawLine(len %d) %.2f ms "
                .. "| drawPixel %.2f ms  -> per call: line %.2f us, pixel %.2f us",
            CALLS, frames,
            accNone / frames * 1000, RUN_LEN, accLine / frames * 1000, accPixel / frames * 1000,
            (accLine - accNone) / frames / CALLS * 1e6,
            (accPixel - accNone) / frames / CALLS * 1e6))
        frames, accLine, accPixel, accNone = 0, 0, 0, 0
    end
end

MESHGHOST_DEV_UNLOAD = function()
    -- A probe that drew is a suspect in every later report until it is known to be gone.
    console.log("MeshGhost DEV: guicost probe unloaded -- it was DRAWING; nothing it painted "
        .. "persists past this frame.")
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
