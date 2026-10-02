-- Turns on the drawn tier's facing-cache trace. Load it before the adapter, which reads the flag as it runs; a Lua
-- global reaches an emulator that is already running, where an environment variable is fixed at launch.
-- Every flag this file owns is set, nil ones included: the dev loader shares one Lua environment, so a global set
-- by an earlier flags file survives a swap.
MESHGHOST_CRYSTAL_FACING_TRACE = true

-- Forces every peer onto one sprite id, which would change what is measured.
MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE = nil

if console and console.log then
	console.log("facing trace ON -- 'facing-trace:' lines go to the adapter's own log file")
end
