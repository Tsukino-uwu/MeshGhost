-- Arms the Emerald draw-order trace, into the adapter's own log: once a second per painted peer, what maskBehindPlayer
-- decided and from what (the ghost's box and band, the player's mask box and band, or NO-MASK), because "the ghost is
-- still on top" is three failures: no mask, no overlap, or a backwards comparison. sort-trace-off.lua stops it.
MESHGHOST_EMERALD_SORT_TRACE = true
console.log("MeshGhost: draw-order trace ARMED (sort-trace-on.lua) -- one SORT line a second per peer")
