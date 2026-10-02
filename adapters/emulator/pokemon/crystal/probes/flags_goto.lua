-- Config only: goto_map.lua's destination and undo slot as globals, since an environment variable is fixed at launch
-- and the loader names paths, not values. Load it before goto_map.lua. Every flag here is set explicitly: the loader
-- shares one Lua environment, and a leftover MESHGHOST_GOTO warps the player on the next load of goto_map.
-- Destinations are goto_map's DESTINATIONS: lighthouse, olivine, route39, icepath, icepathb1, blackthorn, violet.

MESHGHOST_GOTO = "violet"

-- The undo savestate, a slot no prepared state uses; slot 1 is the player's own.
MESHGHOST_GOTO_UNDO_SLOT = 6

-- The raw-id path, unset: either one set would override the name above.
MESHGHOST_GOTO_GROUP = nil
MESHGHOST_GOTO_NUMBER = nil
MESHGHOST_GOTO_WARP = nil

if console and console.log then
	console.log("goto: destination '" .. tostring(MESHGHOST_GOTO)
		.. "', undo savestate slot " .. tostring(MESHGHOST_GOTO_UNDO_SLOT))
end
