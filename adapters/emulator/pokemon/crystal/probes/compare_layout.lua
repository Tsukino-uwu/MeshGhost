-- MeshGhost — Pokémon Crystal: a plain loopback ghost, 2 tiles right (DEV TOOL)
--
-- The three-way compare rig and the hardware tier are BOTH OFF here, deliberately, 2026-08-21.
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
