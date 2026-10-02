-- Arms the Crystal adapter's per-frame motion trace into probes/movetrace_<bridge port>.log: S lines for what this
-- engine sends, R lines per drawn peer, wall-clock stamped. A global outlives its script: crystal-move-trace-off.lua.
MESHGHOST_CRYSTAL_MOVE_TRACE = true
console.log("MeshGhost: Crystal move trace ARMED -- probes/movetrace_<port>.log")
