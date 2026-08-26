-- MeshGhost — Pokémon Crystal: instrument the BIKE POSE question, and nothing else
--
-- Sets globals and does nothing else. Load it BEFORE the adapter in the dev loader's target list.
--
-- THE QUESTION, 2026-08-26. A peer riding the Archipelago build's bike is drawn by the vanilla
-- client's drawn tier and *"looks stuck in the idle bike pose"* while moving. The tier's own
-- counter refutes the obvious cause: 516 of 1512 peer-frames DID draw a stepping view, so step
-- frames are being found and chosen. Four hypotheses reasoned from the code have now failed on
-- this one symptom, which is the point at which `pitfalls.md` says to stop reasoning and put an
-- instrument on it -- the last facing bug went exactly this way and the trace is what ended it.
--
-- WHAT EACH ONE ANSWERS, because they answer different halves:
--
--   FACING_TRACE names every facing the learner ACCEPTS -- the facing, the tile view, the flip,
--   and a marker when one violates the invariant. That is the CACHE's contents: if the stepping
--   views for a direction are identical to its standing view, or the same view is filed under
--   every stride, the pose cannot alternate no matter what picks it.
--
--   SPRITE_TRACE names, per peer, WHICH GRAPHICS it was resolved from -- VRAM or cartridge, and
--   at what base or ROM offset. That is the SOURCE: a bike drawn from the cartridge reads its
--   stepping tiles at ROM 12-23 on the assumption that a sprite carries 24 tiles where its header
--   reports 12. That was measured on the player and one NPC (`documentation.md`); it has never
--   been checked on a BIKE sprite, and if a bike has no stepping half the tier would be reading
--   the next sprite's art or repeating the standing one.
--
-- Both are edge-triggered -- they log when their answer CHANGES, not per frame -- so a steady
-- session writes a handful of lines and neither can cost the game a frame.
--
-- RUN IT ON THE CLIENT THAT IS WATCHING, not the one riding: the peer being drawn is the subject.

MESHGHOST_CRYSTAL_FACING_TRACE = true
MESHGHOST_CRYSTAL_SPRITE_TRACE = true

-- Explicitly off. The dev loader shares ONE Lua environment across every script it loads, so a
-- global set by an earlier flags file survives being swapped out -- "not mentioned" is not "off",
-- and an A/B run is invalid unless every flag is stated (`emulator/CLAUDE.md`).
MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE = nil
MESHGHOST_COMPARE_TIERS = nil
MESHGHOST_CRYSTAL_COMPARE_STATS = nil
MESHGHOST_CRYSTAL_STEP_LAG = nil

console.log("MeshGhost: bike-pose instruments ON (facing trace + sprite trace) -- file only.")
