-- MeshGhost -- disarms the Emerald adapter's draw-order trace (dev loader). The other half of
-- sort-trace-on.lua, and not optional: the flag is a Lua global and survives every script reload.
MESHGHOST_EMERALD_SORT_TRACE = false
console.log("MeshGhost: draw-order trace DISARMED (sort-trace-off.lua)")
