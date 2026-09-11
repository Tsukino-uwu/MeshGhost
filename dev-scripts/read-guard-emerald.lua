-- MeshGhost — Emerald: turn the read guard on (DEV TOOL, never shipped)
--
-- Sets MESHGHOST_EMERALD_READ_GUARD, which makes the adapter's r8/r16/rs16/r32 helpers check every
-- address against the GBA's real memory regions and report the FIRST one that is out of range,
-- with a Lua traceback naming the line that asked for it.
--
-- WHY IT EXISTS. BizHawk answers an out-of-range read with a console warning and a zero: no error,
-- no stack, nothing greppable. On a build whose addresses are wrong that is thousands of lines a
-- second and an emulator at 4fps, and the only way to find the culprit is to guess -- which cost
-- three wrong guesses on EX SPEEDCHOICE 0.4.0 before this existed.
--
-- List it BEFORE the adapter: the flag is read inside the helpers, so it works either way, but
-- loading it first means the very first frame is covered.
--
-- NOT FOR NORMAL PLAY. It adds a bounds check to every memory read the adapter makes.

MESHGHOST_EMERALD_READ_GUARD = true
MG_READ_GUARD_FIRED = nil -- re-arm, so a reload reports again rather than staying quiet

local said = false

MESHGHOST_DEV_TICK = function()
    if not said then
        said = true
        console.log("MeshGhost DEV: READ GUARD on -- the first out-of-range read will be reported "
            .. "once, with a traceback, to the console and to probes/read_guard.log")
    end
end

MESHGHOST_DEV_UNLOAD = function()
    MESHGHOST_EMERALD_READ_GUARD = nil
    console.log("MeshGhost DEV: read guard off.")
end
