-- Sets the Emerald drawn tier's trailing delay to ZERO (dev loader; list BEFORE the adapter, which
-- latches this at load).
--
-- The delay exists to imitate a SPAWNED ghost's natural trailing -- the engine cannot begin or
-- abandon a step mid-tile, so an engine-driven ghost always lags the truth by up to one step. The
-- painted tier has no such rule, so it reproduced the lag deliberately (glideRemote's header).
--
-- The cost, and why the user asked for 0 (2026-09-13): a ghost N frames behind keeps moving for N
-- frames after its peer stops, and the camera stops the instant the player does -- so the delay is
-- spent sliding across a stationary screen. Eight frames is 8px walking and a WHOLE TILE running.
-- At zero the ghost stops when the peer stops, and gives up the imitation.
MESHGHOST_EMERALD_DRAWN_DELAY_FRAMES = 0
console.log("MeshGhost: drawn trailing delay = 0 frames (drawn-delay-0.lua) -- the ghost stops when the peer does")
