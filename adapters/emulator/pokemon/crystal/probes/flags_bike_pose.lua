-- Config only: the facing and sprite traces, for a peer's bike drawn stuck in its idle pose; load it before the
-- adapter on the watching client. The facing trace names every facing the cache accepts (stepping views identical to
-- the standing one show there); the sprite trace names where each peer's graphics resolved from (VRAM or cartridge),
-- so a bike read without a stepping half shows. Both log only when their answer changes.

MESHGHOST_CRYSTAL_FACING_TRACE = true
MESHGHOST_CRYSTAL_SPRITE_TRACE = true

-- Explicitly off: the dev loader shares one Lua environment, so a flag an earlier file set survives its swap.
MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE = nil
MESHGHOST_COMPARE_TIERS = nil
MESHGHOST_CRYSTAL_COMPARE_STATS = nil
MESHGHOST_CRYSTAL_STEP_LAG = nil

console.log("MeshGhost: bike-pose instruments ON (facing trace + sprite trace) -- file only.")
