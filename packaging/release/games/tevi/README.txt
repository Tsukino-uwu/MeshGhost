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
4. OPTIONAL -- only if you want the game to open and close the client for you:
   copy meshghost.exe (two folders up, next to config.json) INTO that MeshGhost folder, so
   you end up with `BepInEx\plugins\MeshGhost\meshghost.exe` sitting alongside
   `BepInEx\plugins\MeshGhost\MeshGhostTevi.dll`.

   Skip this and simply open meshghost.exe yourself before you play -- then it can live
   wherever you like, AS LONG AS config.json sits in the same folder as it. The client
   reads the config.json next to itself, so the two travel as a pair; on its own it falls
   back to 127.0.0.1:7777 and never reaches your host. This mod folder is the ONLY place
   the exe has to be for the mod to start it for you.

   If you do copy it, do it again whenever you update MeshGhost.

Setup, every time you play:
1. Launch TEVI normally through Steam.
   - If you copied meshghost.exe into the mod folder: that is all. The mod starts it
     hidden and shuts it down when you quit -- nothing to open, nothing to leave running.
   - If you did not: open meshghost.exe yourself first, from wherever you keep it, and
     close it when you are done.
   Either way there is nothing to set in config.json about which game it is: the mod tells
   the client that on its own.
2. Walk around. Once a friend joins the same server in the same room, you should see
   their character as a ghost.

If you copied the exe in but want to go back to starting it yourself -- an antivirus that
objects to one program launching another, or you just want to watch its window -- you have
two ways, and the first needs no settings at all:

  - Take meshghost.exe back out of the MeshGhost plugin folder. With nothing there to
    start, the mod simply uses whichever client is already running.
  - Or set MESHGHOST_NO_AUTOSTART and leave the exe where it is. That is an environment
    variable -- a named setting you give Windows rather than a line in a MeshGhost file --
    which every game's mod checks before starting a client; if it exists, the mod starts
    nothing and uses whichever client is already running. Any value works, and the main
    README two folders up has step-by-step instructions under "The MESHGHOST_NO_AUTOSTART
    switch".

Either way, open meshghost.exe yourself before you play.

How far behind is a ghost drawn? ("interp" in config.json)
   A ghost is deliberately drawn a fraction of a second behind where its player really is --
   that buffer is what absorbs the internet between you, and "interp" in config.json is its
   size. Bigger = smoother but more behind; smaller = more immediate but every network
   hiccup shows as a stutter.

   TEVI ships at 450ms, sized so the default survives a genuinely bad connection -- think
   ~200 ping with wobble, 5% packet loss and the odd Wi-Fi dropout, EU<->NA on mediocre
   Wi-Fi. That is measured on TEVI itself on a simulated link exactly that bad: 375ms still
   stuttered once or twice a minute there, 450ms did not.

   Playing on a good same-continent connection (up to ~120 ping)? Measured there too:

       "interp": "300ms"   clean with a little packet loss
       "interp": "175ms"   clean on a good link with no loss; 150ms sat at the edge of stutter

   Values in between behave in between. The tuning
   loop: ghosts stutter = raise it; ghosts feel too far behind on a good connection = lower
   it until you see stutter, then step one notch back. Both players set their own -- it
   only affects what YOUR screen shows.

One note specific to TEVI:
- The mod's local bridge port defaults to 7778 and does not read config.json's
  "local_game_bridge" setting. It can be changed in BepInEx's own per-install config file
  (BepInEx\config\dev.meshghost.tevi.cfg, [Network] BridgePort) if you need to run two
  copies of MeshGhost against two TEVI instances on the same machine -- each instance
  needs its own core process on its own port.
