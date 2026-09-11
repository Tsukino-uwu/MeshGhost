-- MeshGhost — Emerald: what does a gui.* call COST, with no adapter logic at all? (PROBE)
--
-- READ-ONLY of game memory: it reads none. It presses nothing. It DOES draw -- that is the entire
-- experiment -- so it is a probe that changes the picture and must never be left loaded.
--
-- THE QUESTION IT SETTLES.
-- At 64 painted peers the adapter's own profiler attributes 51.5ms of a 55.6ms Lua frame to the
-- painter, across 7,997 runs -- about 6.4us per run. Crystal paints ~6,000 runs in the same
-- situation and holds 60fps, so its whole frame fits in 16.7ms. Emerald spends roughly three
-- times as long on 1.33x the work, and there are exactly two explanations with OPPOSITE fixes:
--
--   A. BizHawk's gui.* calls are expensive at this volume, and our logic is a rounding error.
--      Then the fix is FEWER CALLS -- merge runs, cap the tier, or do not paint at all.
--   B. The per-run logic wrapped around each call (tint maths, panel-exclusion clipping,
--      reflection inclusion-clipping, mirroring, scaling) is the cost.
--      Then the fix is in that loop, and the tier has real headroom.
--
-- So: issue the SAME number of calls the adapter issues, with none of its logic, and time it. If
-- the bare calls alone cost most of 51ms, it is A. If they are cheap, it is B and the loop is the
-- suspect.
--
-- WHY IT ALSO TIMES A ONE-PIXEL CASE SEPARATELY. The measured sprite data averages 1.77 opaque
-- pixels per run, so most runs are 1-2px and the adapter takes a gui.drawPixel path for length 1.
-- A per-CALL cost and a per-PIXEL cost look identical at one length and nothing like each other
-- across two, so both are measured rather than one being assumed representative of the other.
--
-- WHAT IT CANNOT SEE: anything about the adapter (it is not loaded alongside for this), and the
-- emulator's own frame pacing -- os.clock times this Lua, the same limit the adapter's profiler
-- has. Its own drawing is thrown at the top-left 8 rows so it cannot be mistaken for a ghost.

local CALLS = 8000        -- what 64 painted peers actually issue, measured 2026-09-11
local WINDOW = 300        -- report every 300 frames, matching the adapter's profiler
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

    -- 1. The control: the LOOP with no gui call in it, so loop overhead is not charged to gui.
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
    -- It drew: say so on the way out, because a probe that changes the picture is a suspect in
    -- every later report until it is known to be gone.
    console.log("MeshGhost DEV: guicost probe unloaded -- it was DRAWING; nothing it painted "
        .. "persists past this frame.")
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
