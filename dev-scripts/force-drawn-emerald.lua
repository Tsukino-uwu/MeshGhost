-- Forces every Emerald peer onto the painted tier with no relaunch, so the player never moves between rungs: no peer
-- may hold an object slot, and the hardware-sprite tier declines. List it before the adapter, which reads
-- MESHGHOST_EMERALD_HW_OVERFLOW once, at load.

MESHGHOST_EMERALD_MAX_SPAWNED = 0
MESHGHOST_EMERALD_HW_OVERFLOW = "0"

local said = false

MESHGHOST_DEV_TICK = function()
    if not said then
        said = true
        console.log("MeshGhost DEV: DRAWN-ONLY forced (MAX_SPAWNED=0, HW_OVERFLOW=0). "
            .. "Unload this script to restore the normal ladder.")
    end
end

MESHGHOST_DEV_UNLOAD = function()
    -- Unset: the adapter's own defaults again.
    MESHGHOST_EMERALD_MAX_SPAWNED = nil
    MESHGHOST_EMERALD_HW_OVERFLOW = nil
    console.log("MeshGhost DEV: drawn-only released; the spawn and OAM tiers are live again.")
end
