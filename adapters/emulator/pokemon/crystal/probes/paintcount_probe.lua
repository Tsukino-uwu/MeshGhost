-- MeshGhost — Crystal: how many spans is the drawn tier actually painting? (PROBE)
--
-- READ-ONLY. Reads no game memory, presses nothing, draws nothing. It reports the adapter's own
-- MG_CRY_SPANS counter as a per-frame rate, to the console and to a log file beside this script.
--
-- WHY IT EXISTS. A rendering tier that silently stops painting gets FASTER, so a frame-rate
-- improvement with no paint count is indistinguishable from a broken renderer. Emerald's profiler
-- carries `spans/frame` for exactly that reason, and it is what made its 2026-09-11 painted-tier
-- optimisations trustworthy: the count held at 8,035-8,045 across every change, so the picture was
-- the same. Crystal had no equivalent, so a performance change here could not be checked at all.
--
-- HOW TO USE IT: load it alongside the adapter, note the spans/frame, make the change, reload, and
-- compare. The rate must not move. It says nothing about whether the pixels are in the right
-- PLACE -- only that the same amount of painting is happening -- so it narrows what a person has
-- to check on screen, it does not replace them.

local WINDOW = 300 -- frames, matching Emerald's profiler window

local SCRIPT_DIR = (function()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        -- Two separators, written as a character class: Lua needs the backslash doubled inside a
        -- quoted string, and a path here can arrive with either.
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end)()

local LOG = SCRIPT_DIR .. "/paintcount_probe.log"

local frames, last = 0, 0

local function say(line)
    console.log(line)
    local f = io.open(LOG, "a")
    if f then
        f:write(line, "\n")
        f:close()
    end
end

local function tick()
    frames = frames + 1
    if frames >= WINDOW then
        local now = MG_CRY_SPANS or 0
        say(string.format("CRYSTAL PAINT: %.0f spans/frame over %d frames (total %d)",
            (now - last) / frames, frames, now))
        last, frames = now, 0
    end
end

MESHGHOST_DEV_UNLOAD = function()
    -- Owns no game state and wrote nothing; stated rather than assumed.
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
