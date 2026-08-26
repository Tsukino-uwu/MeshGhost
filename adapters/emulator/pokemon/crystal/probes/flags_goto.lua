-- MeshGhost — Pokémon Crystal: pick goto_map.lua's destination and its undo slot
--
-- Sets globals and does nothing else. Load it BEFORE `goto_map.lua` in the dev loader's target
-- list -- goto_map reads both of these as it starts.
--
-- WHY THIS FILE EXISTS AT ALL. `goto_map.lua`'s own header says "set MESHGHOST_GOTO before loading
-- it", and on an emulator that is already running there was no way to do that: an environment
-- variable is fixed when BizHawk starts, and the loader's control file names paths, not values. So
-- the only reachable destination on a live session was goto_map's hardcoded `DEFAULT`. Editing that
-- constant per trip is the thing this replaces -- a repo file quietly holding whatever the last
-- session wanted is how a warp surprises the next one.
--
-- SET EVERY FLAG THIS FILE OWNS, EXPLICITLY. The dev loader shares ONE Lua environment across every
-- script it loads, so a global set by an earlier flags file survives being swapped out -- "not
-- mentioned" is not "off" (pitfalls.md, 2026-08-20). That matters more here than elsewhere: a
-- leftover MESHGHOST_GOTO means the NEXT load of goto_map moves the player somewhere nobody asked
-- for.
--
-- Destinations are the names in goto_map's own DESTINATIONS table: lighthouse, olivine, route39,
-- icepath, icepathb1, blackthorn, violet.
MESHGHOST_GOTO = "violet"

-- THE UNDO SAVESTATE, and it is NOT 8 any more. Slot 8 was this project's warp-undo convention
-- until 2026-08-26, when 8 and 9 became the same-town and cross-town Fly states, 7 the fishing
-- state, 10 the whirlpool and 3 the wrong-trainer route (`agent_docs/status.md`). Slot 1 is the
-- user's. 6 is free; saying so here is what stops a warp silently eating a prepared state.
MESHGHOST_GOTO_UNDO_SLOT = 6

-- The raw-id path, deliberately unset: goto_map takes MESHGHOST_GOTO_GROUP/_NUMBER instead of a
-- name, and either one set would override the name above.
MESHGHOST_GOTO_GROUP = nil
MESHGHOST_GOTO_NUMBER = nil
MESHGHOST_GOTO_WARP = nil

if console and console.log then
	console.log("goto: destination '" .. tostring(MESHGHOST_GOTO)
		.. "', undo savestate slot " .. tostring(MESHGHOST_GOTO_UNDO_SLOT))
end
