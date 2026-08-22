-- MeshGhost — Pokémon Crystal: turn on the drawn tier's facing-cache trace
--
-- Sets ONE global and does nothing else. Load it BEFORE the adapter in the dev loader's target
-- list, because the adapter reads the flag as it runs.
--
-- WHY A FLAGS FILE AND NOT AN ENVIRONMENT VARIABLE: an environment variable is fixed when the
-- process starts, so it can only configure an emulator you are about to launch. A Lua global can
-- be set into an emulator that is already running and already has the game in the state you want
-- to measure, which is every session that matters.
--
-- SET EVERY FLAG THIS FILE OWNS, EXPLICITLY, INCLUDING THE FALSE ONES. The dev loader shares ONE
-- Lua environment across every script it loads, so a global set by an earlier flags file survives
-- being swapped out -- "not mentioned" is not "off", and an A/B run is invalid unless the flags
-- are exhaustive (pitfalls.md, 2026-08-20).
MESHGHOST_CRYSTAL_FACING_TRACE = true

-- Not this one: it forces every peer onto a single sprite id and would change what is being
-- measured here. Named rather than omitted, for the reason above.
MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE = nil

if console and console.log then
	console.log("facing trace ON -- 'facing-trace:' lines go to the adapter's own log file")
end
