-- Restores the Emerald drawn tier's OLD 8-frame trailing delay (dev loader; list BEFORE the
-- adapter, which latches this at load).
--
-- The shipped default is 0 since 2026-09-13: the bar is the PEER'S OWN MOTION -- the user,
-- *"a ghost is never in the same game, but its supposed to look 1:1 to what a player did in
-- another game"* -- and a delay makes the ghost lag the thing it is meant to reproduce.
--
-- The 8 exists for ONE case, which is the case it was written for: a TIER COMPARISON, both
-- renderers of a single peer on screen together (MESHGHOST_COMPARE_TIERS). A spawned ghost trails
-- by up to a step because the engine cannot begin one mid-tile, so matching it needs this back.
MESHGHOST_EMERALD_DRAWN_DELAY_FRAMES = 8
console.log("MeshGhost: drawn trailing delay = 8 frames (drawn-delay-8.lua) -- the old tier-comparison value")
