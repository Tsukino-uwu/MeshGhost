-- Config only: the loopback ghost drawn twice from one state, compare rig on (spawned 3 tiles right, as COMPARE.spawned
-- overrides the loopback offset; painted 2 left), hardware tier off: it claims a peer before the drawn tier sees it,
-- so an unconfirmed rung above a confirmed one costs a vanished peer. Every switch is set, off included: the loader
-- replaces files, never globals, so a value an older version of this file set would outlive it.

MESHGHOST_COMPARE_TIERS = true
MESHGHOST_CRYSTAL_OAM_OVERFLOW = "0"
MESHGHOST_LOOPBACK_OFFSET_X = 2
console.log("MeshGhost dev: drawn ghost 2 tiles LEFT, spawned ghost 2 tiles RIGHT; hardware tier OFF")
MESHGHOST_DEV_TICK = function() end
