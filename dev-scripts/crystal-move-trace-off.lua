-- Disarms the Crystal adapter's motion trace (see crystal-move-trace-on.lua). A global outlives the
-- script that set it, so switching the trace off takes this explicit write, not dropping the other file.
MESHGHOST_CRYSTAL_MOVE_TRACE = false
console.log("MeshGhost: Crystal move trace OFF")
