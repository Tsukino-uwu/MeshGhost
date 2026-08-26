-- MeshGhost — Pokémon Crystal: turn on the step-lag instrument, and with it the WHY line
--
-- Sets globals and does nothing else. Load it BEFORE the adapter in the dev loader's target list,
-- because the adapter reads these as it runs.
--
-- WHAT IT IS FOR HERE, 2026-08-26. `MESHGHOST_CRYSTAL_STEP_LAG`'s headline job is timing a spawned
-- ghost's step-start lag on loopback, and that half is useless in a two-machine room -- there is no
-- local player frame to subtract, and the flag says so by counting those arrivals rather than
-- averaging them in. The half that matters right now is its OTHER output: **once a second, for any
-- peer that is NOT spawned, it names which of the three terms refused** -- `wearable`, `blocking`,
-- `paceable` -- together with the peer's sprite, the local player's sprite, how long the peer has
-- been idle, and how long it stays passable.
--
-- That line exists because a count of zero cannot be interrogated. A run showing "0 spawned as
-- real objects" looks identical whether the peer is being held on the drawn tier deliberately, or
-- the engine has no free slot, or a term is wrong -- and on 2026-08-26 that zero was read as if it
-- meant one particular thing for most of a session. `FLAGS.md` carries the full row.
--
-- IT WRITES NO GAME MEMORY and changes no decision. Read-only, file-only, once a second.
--
-- SET EVERY FLAG THIS FILE OWNS, EXPLICITLY, INCLUDING THE FALSE ONES. The dev loader shares one
-- Lua environment across every script it loads, so a global set by an earlier flags file survives
-- being swapped out -- "not mentioned" is not "off".

MESHGHOST_CRYSTAL_STEP_LAG = "1"

-- Not this one. Named so the two are never confused: COMPARE_TIERS renders a second copy of the
-- loopback ghost, which in a two-machine room is not what is wanted and would put an extra
-- character on screen in the middle of investigating an extra character on screen.
MESHGHOST_COMPARE_TIERS = nil
MESHGHOST_CRYSTAL_COMPARE_STATS = nil

console.log("MeshGhost: step-lag instrument ON -- the drawn tier will name which term refused, "
	.. "once a second, in the adapter's own log file (not here).")
