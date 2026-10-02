-- Turns on the step-lag instrument for its other output: once a second, for any peer that is not spawned, the
-- adapter's log names which term refused it (wearable, blocking, paceable), which a count of zero cannot say.
-- Read-only. Load it before the adapter. Every flag this file owns is set, nil ones included: the dev loader shares
-- one Lua environment, so a global set by an earlier flags file survives a swap.

MESHGHOST_CRYSTAL_STEP_LAG = "1"

-- Compare tiers would put a second copy of the loopback ghost on screen.
MESHGHOST_COMPARE_TIERS = nil
MESHGHOST_CRYSTAL_COMPARE_STATS = nil

console.log("MeshGhost: step-lag instrument ON -- the drawn tier will name which term refused, "
	.. "once a second, in the adapter's own log file (not here).")
