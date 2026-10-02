-- Turns on the Emerald adapter's read guard: r8/r16/rs16/r32 report the first read outside the GBA's memory regions,
-- once, with a traceback, where BizHawk alone answers a console warning and a zero. List it before the adapter so
-- the first frame is covered. It adds a check to every read, so it is not for normal play.

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
