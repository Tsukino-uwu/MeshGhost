-- MeshGhost — Pokémon Crystal: all three tiers at once, on their own tiles (DEV TOOL)
--
-- The user's layout, 2026-08-21: *"OAM 4 tiles to the left, DRAWN 2 tiles to the left, SPAWNED 2
-- tiles to the right"* -- alongside the hard rule that no two rendered characters may share a tile
-- during local testing, because overlapping sprites make two different faults look like one and
-- only the user can see the screen.
--
-- MESHGHOST_COMPARE_TIERS renders the ONE loopback ghost more than once from the same peer state in
-- the same frame, so the renderers are comparable in one place rather than across two runs where
-- the location has changed underneath the comparison.
--
-- Both switches are read as GLOBALS before the environment (FLAGS.md), and the dev loader loads its
-- targets in the order the control file lists them -- so listing this file ABOVE the adapter sets
-- them without relaunching the emulator.
MESHGHOST_COMPARE_TIERS = true
MESHGHOST_CRYSTAL_OAM_OVERFLOW = "1"
console.log("MeshGhost dev: compare tiers on, hardware tier on")
MESHGHOST_DEV_TICK = function() end
