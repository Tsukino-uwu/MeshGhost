-- MeshGhost — DEV switch for ghost graphics (loader target; list BEFORE the adapter)
--
-- ALWAYS ASSIGNS BOTH GLOBALS, including when turning something off. Lua globals live in the
-- emulator's Lua state and survive a script reload -- so commenting a line out does NOT unset it,
-- it just leaves the previous session's value in place. That cost a confusing reload on
-- 2026-08-18 where a ghost stayed forced onto a bike after the line that forced it was gone.
--
--   0 Brendan normal | 1 Mach Bike | 63 Acro Bike | 2 surfing | 137 fishing
--  89 May normal     | 90 Mach Bike | 91 Acro Bike | 92 surfing | 138 fishing

MESHGHOST_FORCE_GHOST_GFX = nil   -- a graphics id to force every ghost to, or nil
MESHGHOST_GHOST_PEER_GFX = nil    -- true to draw ghosts with the PEER's own graphic (corrupts
                                  -- for the 32-wide states -- see the adapter's comment)

MESHGHOST_DEV_TICK = function() end
