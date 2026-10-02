-- Turns on the Emerald adapter's section profiler: every 300 frames, its Lua frame's average and worst and its named
-- sections, to the console and the adapter's log. It sees only the adapter's Lua, so a small number with a low frame
-- rate puts the cost elsewhere. Pair it with force-drawn-emerald.lua to price one rung. Its os.clock calls are cheap,
-- not free: re-take a reading that matters with it unloaded.

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
