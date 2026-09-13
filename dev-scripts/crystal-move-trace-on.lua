-- Arms the Crystal adapter's per-frame motion trace (dev loader): `S` lines for what this client's
-- engine sends, `R` lines per drawn peer for what arrives and what the model does, wall-clock stamped.
-- Written to adapters/emulator/pokemon/crystal/probes/movetrace_<bridge port>.log. A global outlives
-- the script that set it: crystal-move-trace-off.lua is how it stops.
MESHGHOST_CRYSTAL_MOVE_TRACE = true
console.log("MeshGhost: Crystal move trace ARMED -- probes/movetrace_<port>.log")
