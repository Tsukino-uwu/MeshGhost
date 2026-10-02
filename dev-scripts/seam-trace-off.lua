-- Disarms the Emerald seam trace: a global survives every reload, so dropping seam-trace-on.lua leaves the trace on
-- and its log growing. Load this, confirm the console line, then drop both.
MESHGHOST_EMERALD_SEAM_TRACE = false
console.log("MeshGhost: seam trace DISARMED (seam-trace-off.lua)")
