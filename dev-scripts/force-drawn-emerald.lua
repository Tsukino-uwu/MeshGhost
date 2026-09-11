-- MeshGhost — Emerald: force EVERY peer onto the DRAWN tier (DEV TOOL, never shipped)
--
-- Sets nothing in game memory. It sets the two adapter flags that decide which rung of the
-- `spawn -> OAM -> drawn` ladder a peer lands on, both documented in the adapter's FLAGS.md as
-- "global first, then environment" and re-read every call -- which is what makes them flippable
-- from a loader script mid-session, with no emulator relaunch.
--
--   MESHGHOST_EMERALD_MAX_SPAWNED = 0   -- no peer may hold a real object slot
--   MESHGHOST_EMERALD_HW_OVERFLOW = "0" -- the hardware-sprite tier declines
--
-- Everything therefore falls through to the painted tier, which is the rung being priced.
--
-- WHY A SCRIPT AND NOT AN ENV VAR: the env var is read at launch, so using it means relaunching
-- the emulator and re-reaching the same spot on the map -- and the ladder's whole point is that
-- the player stands in ONE place for every rung. This flips the tier between runs without the
-- player moving at all, which removes "was the scene the same?" from the comparison.
--
-- NEVER LEAVE IT LOADED. It deliberately starves the two tiers that are free, so any performance
-- reading taken with it on describes the worst rung, not the adapter.

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
    -- Put the ladder back exactly as it was: unset, meaning "use the real budget".
    MESHGHOST_EMERALD_MAX_SPAWNED = nil
    MESHGHOST_EMERALD_HW_OVERFLOW = nil
    console.log("MeshGhost DEV: drawn-only released; the spawn and OAM tiers are live again.")
end
