-- MeshGhost — DEV switches for ghost graphics (loader target; list BEFORE the adapter)
--
-- ASSIGNS EVERY SWITCH, ALWAYS, including the ones being turned off. Lua globals live in the
-- emulator's Lua state and survive a script reload, so a switch left out of this file keeps
-- whatever a previous experiment set it to. That has now caused two confusing runs on
-- 2026-08-18: a ghost that stayed forced onto a bike after the forcing line was removed, and a
-- ghost still sharing the player's VRAM tiles from an experiment three reloads earlier.
MESHGHOST_FORCE_GHOST_GFX = 2     -- graphics id to force, or nil
MESHGHOST_GHOST_PEER_GFX = nil    -- true to use the peer's own graphic
MESHGHOST_DEBUG_SKIP_OAM_COPY = nil
MESHGHOST_DEBUG_SHARE_PLAYER_TILES = nil
MESHGHOST_DEV_TICK = function() end
