-- MeshGhost — Pokémon Crystal: send goto_map.lua to Route 39 (DEV TOOL, one line of config)
--
-- The user, 2026-08-21: Route 39 is *"the most demanding one in the whole game... a big route, and
-- fills up things due to having a lot of npc's"*, and *"if things are stable in that map, it will
-- be better anywhere else. route 39 should be the 'worst case'"*.
--
-- List this ABOVE goto_map.lua in the loader's control file; the loader loads its targets in order.
MESHGHOST_GOTO = "route39"
MESHGHOST_DEV_TICK = function() end
