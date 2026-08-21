-- MeshGhost — Pokémon Crystal: two ghosts, on their own tiles, one per renderer (DEV TOOL)
--
-- The user's layout, 2026-08-21: *"place 1 ghost 2 tiles to the right of the player. and the other
-- one 2 tiles to the left of the player"* -- given alongside the hard rule that no two rendered
-- characters may share a tile during local testing, because overlapping sprites make two different
-- faults look like one and only the user can see the screen.
--
-- MESHGHOST_COMPARE_TIERS renders the ONE loopback ghost twice from the same peer state in the
-- same frame: SPAWNED two tiles right, DRAWN two tiles left. That is exactly the requested layout,
-- and it also makes the two renderers directly comparable in one place.
--
-- Both switches are read as GLOBALS before the environment (FLAGS.md), and the dev loader loads
-- its targets in the order the control file lists them -- so listing this file ABOVE the adapter
-- sets them without relaunching the emulator.
MESHGHOST_COMPARE_TIERS = true
console.log("MeshGhost dev: compare tiers on -- spawned 2 tiles right, drawn 2 tiles left")
MESHGHOST_DEV_TICK = function() end
