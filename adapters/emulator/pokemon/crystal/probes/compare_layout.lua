-- MeshGhost — Pokémon Crystal: the loopback ghost rendered TWICE (DEV TOOL)
--
-- The compare rig is ON and the hardware tier is OFF. One peer, two renderers in the same frame
-- from the same state: SPAWNED 2 tiles right, PAINTED 2 tiles left. Confirmed from the adapter's
-- own startup line on 2026-08-25 (`PROBE FLAG IN USE: MESHGHOST_COMPARE_TIERS`); the header used
-- to say the rig was off, which is what it was when the file was written on 2026-08-21 and had
-- stopped being true. FLAGS.md's rule settles that kind of disagreement: the value wins.
--
-- THE HARDWARE TIER STAYS OFF, and that half of the 2026-08-21 reasoning is unchanged.
--
-- Why: with the hardware tier on it claims a peer BEFORE the drawn tier sees it, and the user's
-- report was that a peer then *"goes invisible when standing idle for a tiny bit"* -- which is
-- exactly what claiming-and-not-rendering looks like. A rung whose visual correctness is
-- unconfirmed must not sit ABOVE a rung that is confirmed, because the cost of it being wrong is
-- the peer disappearing rather than looking slightly off.
--
-- Set MESHGHOST_CRYSTAL_OAM_OVERFLOW = "1" and MESHGHOST_COMPARE_TIERS = true here to put the rig
-- back once the hardware tier renders something the user can actually see.
-- EVERY switch is set explicitly, including the ones being turned OFF. The loader replaces files,
-- never globals: a `true` set by a previous version of this file survives its own deletion and keeps
-- the compare rig on with no file left that mentions it. pitfalls.md has carried this since
-- 2026-08-19 as "A probe global outlives the probe, and then looks exactly like a real bug", and it
-- was walked into twice more on 2026-08-21 by someone who had not read that file.
MESHGHOST_COMPARE_TIERS = true
MESHGHOST_CRYSTAL_OAM_OVERFLOW = "0"
MESHGHOST_LOOPBACK_OFFSET_X = 2
console.log("MeshGhost dev: drawn ghost 2 tiles LEFT, spawned ghost 2 tiles RIGHT; hardware tier OFF")
MESHGHOST_DEV_TICK = function() end
