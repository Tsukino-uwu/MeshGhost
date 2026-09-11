-- MeshGhost — Emerald: turn the adapter's own section profiler on (DEV TOOL, never shipped)
--
-- Sets MESHGHOST_EMERALD_PROFILE, which makes the adapter time its Lua frame and five named
-- sections -- send, drain, sync, shadows, draw -- and report the window's average and WORST frame
-- every 300 frames. Since 2026-09-11 that report goes to the adapter's log file as well as the
-- console, so it can be collected without a person reading the emulator's GUI.
--
-- WHY A SEPARATE SCRIPT FROM force-drawn-emerald.lua: the two answer different questions and are
-- useful apart. Forcing the tier says WHICH rung is being paid for; profiling says WHERE inside
-- the frame the time goes. Pair them to price one rung; load this alone to profile normal play.
--
-- WHAT IT CANNOT SEE, and this is the point of the flag's own documentation: anything outside this
-- adapter's Lua. A small number here with a low frame rate means the cost is in the emulator core
-- or another loaded script -- which is exactly how the BuildOamBuffer hook was exonerated
-- (2026-08-20, pitfalls.md). Read it as "how much of the frame is OURS", not as the frame time.
--
-- Its own cost is a handful of os.clock calls per frame. Cheap, but not free, and an instrument is
-- always a suspect: a reading that matters gets re-taken with this unloaded.

MESHGHOST_EMERALD_PROFILE = true

local said = false

MESHGHOST_DEV_TICK = function()
    if not said then
        said = true
        console.log("MeshGhost DEV: section profiler ON -- a PROFILE line every 300 frames, "
            .. "to the console and to the adapter's log file.")
    end
end

MESHGHOST_DEV_UNLOAD = function()
    MESHGHOST_EMERALD_PROFILE = nil
    console.log("MeshGhost DEV: section profiler off.")
end
