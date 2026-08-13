MeshGhost -- TEVI setup
========================

STATUS: EXPERIMENTAL. This mod is code-complete but has not yet been confirmed working
over a real network with a second player (Steam won't run two TEVI instances on one
machine, so this couldn't be tested locally -- see the main project's
agent_docs/phases/phase6.md if you're curious). If something doesn't work, that's useful
information -- there's nowhere to report it yet, but don't assume it's your setup.

What you need, once:
- Your own legally-obtained copy of TEVI.
- BepInEx 5.4.x, 64-bit, Mono build (NOT IL2CPP -- TEVI is a Mono game). Get it from
  https://github.com/BepInEx/BepInEx/releases (look for a "BepInEx_x64" 5.4.x build, NOT
  a "5.5"/IL2CPP build). Not included -- see the main project's agent_docs/licensing.md.

What's in this folder:
- MeshGhostTevi.dll -- the mod itself. This is the ONLY file from here that goes into
  your TEVI install.

Setup, once:
1. If you haven't already, install BepInEx into your TEVI folder (the one containing
   TEVI.exe): unzip BepInEx's release into that folder so `winhttp.dll`, `doorstop_config.ini`,
   and a `BepInEx\` folder end up sitting next to TEVI.exe.
2. Run TEVI once and close it again -- this lets BepInEx finish setting itself up and
   creates the `BepInEx\plugins\` folder.
3. Copy MeshGhostTevi.dll into `BepInEx\plugins\MeshGhostTevi\MeshGhostTevi.dll` (create
   the MeshGhostTevi folder if it doesn't exist).

Setup, every time you play:
1. Double-click meshghost.exe (one folder up). Leave the window open.
2. Launch TEVI normally through Steam. The mod loads automatically via BepInEx -- no
   separate script to open, and nothing to set in config.json -- the mod tells
   meshghost.exe which game it is on its own.
3. Walk around. Once a friend joins the same server in the same room, you should see
   their character as a ghost.

Two important notes specific to TEVI:
- The mod always uses local bridge port 7778 and does not read config.json's
  "local_game_bridge" setting (it's hardcoded in the mod itself right now). If you're
  trying to run two copies of MeshGhost on the same machine (see the main README.txt),
  that trick does not currently work for TEVI.
- No cross-area filtering yet: if you and a friend are in different areas of the game,
  you may still see each other's ghost as if you were in the same place. This is a known
  gap, not a bug you're causing.
