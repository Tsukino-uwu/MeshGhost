MeshGhost -- Pseudoregalia setup
=================================

STATUS: EXPERIMENTAL. This mod is code-complete -- ghost spawning, positioning, facing,
and movement animations have all been confirmed working live, solo -- but it has NOT yet
been tested with a real second player over a real network. If something doesn't work with
two players, that's useful information -- there's nowhere to report it yet, but don't
assume it's your setup.

What you need, once:
- Your own legally-obtained copy of Pseudoregalia.
- UE4SS v3.0.1 Beta (or compatible), installed into your Pseudoregalia folder (the one
  containing pseudoregalia-Win64-Shipping.exe). Get it from
  https://github.com/UE4SS-RE/RE-UE4SS/releases -- unzip its contents into that folder so
  a `ue4ss\` folder and `dwmapi.dll` end up sitting next to the game's .exe. Not included --
  see the main project's agent_docs/licensing.md.

What's in this folder:
- MeshGhostPseudo\ -- the mod itself, laid out exactly as UE4SS expects a mod folder
  (dlls\main.dll + enabled.txt). Copy the whole MeshGhostPseudo folder, not just the DLL.

Setup, once:
1. Install UE4SS into your Pseudoregalia folder as described above, then run the game once
   and close it again to let UE4SS finish setting itself up (creates `ue4ss\Mods\`).
2. Copy the MeshGhostPseudo folder from here into `ue4ss\Mods\MeshGhostPseudo\`.

Setup, every time you play:
1. Double-click meshghost.exe (one folder up). Leave the window open.
2. Launch Pseudoregalia normally. The mod loads automatically via UE4SS -- no separate
   script to open, and nothing to set in config.json -- the mod tells meshghost.exe which
   game it is on its own.
3. Walk around. Once a friend joins the same server in the same room, you should see their
   goat as a ghost -- correct position, facing, and movement animations.

Two important notes specific to Pseudoregalia:
- The mod always uses local bridge port 7778 and does not read config.json's
  "local_game_bridge" setting (it's hardcoded in the mod itself right now). If you're
  trying to run two copies of MeshGhost on the same machine (see the main README.txt),
  that trick does not currently work for Pseudoregalia.
- No cross-area filtering yet: if you and a friend are in different areas of the castle,
  you may still see each other's ghost as if you were in the same place. This is a known
  gap, not a bug you're causing.
