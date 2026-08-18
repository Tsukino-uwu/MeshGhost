MeshGhost -- TEVI setup
========================

STATUS: EXPERIMENTAL. This mod is code-complete and has been confirmed working with two
real local instances on one machine, including cross-area filtering and ghost cleanup on
disconnect -- see the main project's agent_docs/phases/phase6.md if you're curious. It has
not yet been confirmed over a real network between two separate machines. If something
doesn't work, that's useful information -- there's nowhere to report it yet, but don't
assume it's your setup.

What you need, once:
- Your own legally-obtained copy of TEVI.
- BepInEx 5.4.x, 64-bit, Mono build (NOT IL2CPP -- TEVI is a Mono game). Get it from
  https://github.com/BepInEx/BepInEx/releases (look for a "BepInEx_x64" 5.4.x build, NOT
  a "5.5"/IL2CPP build). Not included -- see the main project's agent_docs/licensing.md.

What's in this folder:
- MeshGhost\ -- the mod itself.
  Drag this whole MeshGhost folder into your TEVI install's BepInEx\plugins\ folder.

Setup, once:
1. If you haven't already, install BepInEx into your TEVI folder (the one containing
   TEVI.exe): unzip BepInEx's release into that folder so `winhttp.dll`, `doorstop_config.ini`,
   and a `BepInEx\` folder end up sitting next to TEVI.exe.
2. Run TEVI once and close it again -- this lets BepInEx finish setting itself up and
   creates the `BepInEx\plugins\` folder.
3. Drag the MeshGhost folder (from this folder) into `BepInEx\plugins\`, so you end up with
   `BepInEx\plugins\MeshGhost\MeshGhostTevi.dll`.
4. Copy meshghost.exe (two folders up, next to config.json) INTO that MeshGhost folder,
   so you end up with `BepInEx\plugins\MeshGhost\meshghost.exe` sitting alongside
   `BepInEx\plugins\MeshGhost\MeshGhostTevi.dll`.

   Do this again whenever you update MeshGhost.

Setup, every time you play:
1. Launch TEVI normally through Steam. That is all -- the mod loads via BepInEx and starts
   meshghost.exe itself, hidden, and shuts it down again when you quit. Nothing to open,
   nothing to leave running, and nothing to set in config.json: the mod tells the client
   which game it is on its own.
2. Walk around. Once a friend joins the same server in the same room, you should see
   their character as a ghost.

If you would rather start the client yourself (an antivirus that objects to one program
launching another, or you want to watch its window), set the environment variable
MESHGHOST_NO_AUTOSTART to anything and run meshghost.exe by hand as before.

One note specific to TEVI:
- The mod's local bridge port defaults to 7778 and does not read config.json's
  "local_game_bridge" setting. It can be changed in BepInEx's own per-install config file
  (BepInEx\config\dev.meshghost.tevi.cfg, [Network] BridgePort) if you need to run two
  copies of MeshGhost against two TEVI instances on the same machine -- each instance
  needs its own core process on its own port.
