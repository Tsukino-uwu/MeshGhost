-- Turns on the two-renderer compare rig: the one loopback ghost drawn twice in the same frame from the same peer
-- state, spawned three tiles right of the player and painted two tiles left. What the painted tier misses is a
-- question about a place, which flipping a flag between two runs cannot answer. Load it before the adapter. Every
-- flag this file owns is set, nil ones included: the dev loader shares one Lua environment.
MESHGHOST_COMPARE_TIERS = true

-- The per-frame instruments can drop frames, which desyncs the two tiers being compared.
MESHGHOST_CRYSTAL_COMPARE_STATS = nil

-- Not blocking means rendered by the drawn tier in this adapter, so it would delete the spawned copy.
MESHGHOST_CRYSTAL_GHOSTS_PASSABLE = nil

-- One pins what this client sends (and changes shipped collision), the other forces every peer onto one sprite id.
MESHGHOST_CRYSTAL_FREEZE_STATE = nil
MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE = nil

if console and console.log then
	console.log("compare rig ON -- painted ghost 2 tiles LEFT, spawned ghost 2 tiles RIGHT")
end
