-- Arms the Emerald seam trace on a running game: the adapter reads the global every frame, so listed above the
-- adapter it is on within half a second. It cannot move a ghost, but it still comes off before a verdict.
-- A global outlives its script: seam-trace-off.lua is how it stops.
MESHGHOST_EMERALD_SEAM_TRACE = true
console.log("MeshGhost: seam trace ARMED (seam-trace-on.lua) -- a window around every crossing "
    .. "goes to adapters/emulator/pokemon/emerald/probes/seamtrace.log")
