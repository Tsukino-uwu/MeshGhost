-- Scratch probe slot: a permanently registered, empty mod, so a new probe can be hot-loaded without a relaunch
-- (RestartMod only restarts mods UE4SS knew at launch). Write a probe over this file, then trigger the reloader:
--
--     copy <your probe>.lua  <install>\ue4ss\Mods\MeshGhostScratch\Scripts\main.lua
--     echo MeshGhostScratch <nonce>  >  <install>\ue4ss\Mods\MeshGhostProbeReloader\reload_request.txt
--
-- Confirm the restart in UE4SS.log. Restore this stub when done: a probe left here loads at the next launch under
-- a name that says nothing. No LoopAsync, no FindAllOf, no reads, so an idle slot costs nothing.

print("[MeshGhostScratch] empty slot loaded -- overwrite Scripts/main.lua with a probe and trigger the reloader.\n")
