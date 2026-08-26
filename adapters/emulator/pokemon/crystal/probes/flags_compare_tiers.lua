-- MeshGhost — Pokémon Crystal: turn on the two-renderer compare rig
--
-- Sets globals and does nothing else. Load it BEFORE the adapter in the dev loader's target list,
-- because the adapter reads these as it runs.
--
-- WHAT IT GIVES YOU: the ONE loopback ghost rendered TWICE in the same frame from the same peer
-- state -- spawned two tiles to the right of the player, painted two tiles to the left. What the
-- painted renderer is missing is a question about a PLACE, and flipping a flag between two runs
-- cannot answer it because the place has changed by the time the other renderer is on. `FLAGS.md`
-- carries the full row for `MESHGHOST_COMPARE_TIERS`, including why it is not gated on the drawn
-- tier's own switch.
--
-- WHY A FLAGS FILE AND NOT AN ENVIRONMENT VARIABLE: an environment variable is fixed when the
-- process starts, so it can only configure an emulator you are about to launch. A Lua global can
-- be set into an emulator that is already running and already has the game in the state you want
-- to measure, which is every session that matters.
--
-- SET EVERY FLAG THIS FILE OWNS, EXPLICITLY, INCLUDING THE FALSE ONES. The dev loader shares ONE
-- Lua environment across every script it loads, so a global set by an earlier flags file survives
-- being swapped out -- "not mentioned" is not "off", and an A/B run is invalid unless the flags
-- are exhaustive (pitfalls.md, 2026-08-20). The sibling of `flags_facing_trace.lua`, which owns a
-- different set; loading both is fine and each still states its own.
MESHGHOST_COMPARE_TIERS = true

-- NOT the measuring half. `MESHGHOST_COMPARE_TIERS` alone means WATCHING -- both copies rendered,
-- the once-a-second summaries. `COMPARE_STATS` adds the per-frame instruments that grew inside the
-- rig until the user reported the game *"laggy when the scripts are running"* mid-comparison
-- (2026-08-25), and a probe heavy enough to drop frames desyncs the two tiers it exists to compare.
MESHGHOST_CRYSTAL_COMPARE_STATS = nil

-- NOT this one, and naming it is the point: "nothing blocks, ever" is not a collision flag in this
-- adapter -- "not blocking" IS "rendered by the drawn tier" by design, so it would delete the
-- spawned copy this rig exists to compare against.
MESHGHOST_CRYSTAL_GHOSTS_PASSABLE = nil

-- Neither of these: one pins what this client sends (and silently changes shipped collision), the
-- other forces every peer onto one sprite id. Both would change what is being watched.
MESHGHOST_CRYSTAL_FREEZE_STATE = nil
MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE = nil

if console and console.log then
	console.log("compare rig ON -- painted ghost 2 tiles LEFT, spawned ghost 2 tiles RIGHT")
end
