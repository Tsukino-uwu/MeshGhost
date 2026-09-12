-- MeshGhost -- disarms the Emerald adapter's seam trace on a RUNNING game (dev loader).
--
-- The other half of seam-trace-on.lua, and not optional: the flag is a Lua GLOBAL, so it survives
-- every script reload in the emulator's own state. Removing the ON file from the loader's target
-- list leaves the trace running and its log growing, with nothing on screen or in the target file
-- saying so -- which is exactly how a probe ends up loaded during a verdict it then gets blamed
-- for. Load this, confirm the console line, then drop both from the target list.
MESHGHOST_EMERALD_SEAM_TRACE = false
console.log("MeshGhost: seam trace DISARMED (seam-trace-off.lua)")
