-- MeshGhost -- arms the Emerald adapter's draw-order trace on a RUNNING game (dev loader).
--
-- Prints, once a second per painted peer, what `maskBehindPlayer` decided and the numbers it
-- decided from: the ghost's box and sort band, the player's mask box and band, or NO-MASK when the
-- player's own pixels could not be built. Exists because "the ghost is still on top" is three
-- different failures wearing one face -- no mask, no overlap, or a backwards comparison.
--
-- Writes to the adapter's own log (adapters/emulator/pokemon/emerald/logs/), not to a probe file.
-- A GLOBAL OUTLIVES THE SCRIPT: dropping this from the loader's target list does NOT turn it off,
-- sort-trace-off.lua does.
MESHGHOST_EMERALD_SORT_TRACE = true
console.log("MeshGhost: draw-order trace ARMED (sort-trace-on.lua) -- one SORT line a second per peer")
