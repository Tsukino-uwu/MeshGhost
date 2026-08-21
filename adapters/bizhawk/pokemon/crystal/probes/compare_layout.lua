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
-- Set EXPLICITLY, not left to the default. A global set by a previously-loaded dev script stays in
-- the Lua state after that script is dropped -- an earlier session global of 3 outlived the file
-- that set it and quietly put the spawned ghost a tile further out than the layout says.
MESHGHOST_LOOPBACK_OFFSET_X = 0 -- 0 = let the compare rig choose; it uses +2 for the spawned copy
MESHGHOST_COMPARE_TIERS = true
MESHGHOST_CRYSTAL_OAM_OVERFLOW = "1"
console.log("MeshGhost dev: compare tiers on, hardware tier on")
MESHGHOST_DEV_TICK = function() end
