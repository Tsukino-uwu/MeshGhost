-- Dev toggle: run the Emerald adapter with the draw-order mask SUBTRACTED OUT (see
-- MESHGHOST_EMERALD_NO_SORT in the adapter). For A/B-ing a symptom against the feature.
-- A global outlives the script that set it; sort-on.lua puts it back.
MESHGHOST_EMERALD_NO_SORT = true
console.log("MeshGhost: draw-order mask DISABLED (no-sort.lua) -- ghosts paint over the player again")
