-- MeshGhost -- arms the Emerald adapter's seam trace on a RUNNING game (dev loader; never ships).
--
-- The adapter reads MESHGHOST_EMERALD_SEAM_TRACE every frame rather than latching it at load, so
-- this is the hot-reload way in: name this file ABOVE the adapter in the loader's target file and
-- the trace is on within half a second, with no emulator relaunch (CLAUDE.md: hot reload is the
-- default loop).
--
-- WHAT IT COSTS while armed: one string.format per frame per peer, a 60-line ring buffer, and one
-- file write per crossing -- no memory writes, nothing spawned, nothing drawn. It cannot move a
-- ghost, which is what makes it safe to judge a crossing with it loaded. It still comes OFF before
-- a verdict (seam-trace-off.lua), because "a probe can break the thing it measures" is a rule
-- about probes, not about probes that look expensive.
--
-- A GLOBAL OUTLIVES THE SCRIPT THAT SET IT. Dropping this file from the target list does NOT turn
-- the trace off -- the global is still true in the emulator's Lua state until something sets it
-- false, which is what seam-trace-off.lua is for. Same trap as MESHGHOST_EMERALD_TEST_PEER's
-- "off", and the reason both halves exist as files.
MESHGHOST_EMERALD_SEAM_TRACE = true
console.log("MeshGhost: seam trace ARMED (seam-trace-on.lua) -- a window around every crossing "
    .. "goes to adapters/emulator/pokemon/emerald/probes/seamtrace.log")
