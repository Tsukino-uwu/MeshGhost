MeshGhost -- Pseudoregalia setup
=================================

STATUS: EXPERIMENTAL. This mod is code-complete -- ghost spawning, positioning, facing,
and movement animations have all been confirmed working live, solo -- but it has NOT yet
been tested with a real second player over a real network. If something doesn't work with
two players, that's useful information -- there's nowhere to report it yet, but don't
assume it's your setup.

What you need, once:
- Your own legally-obtained copy of Pseudoregalia. That's it -- everything else the mod
  needs is already in this folder.

What's in this folder:
- pseudoregalia\ -- the mod, already in the folder shape your game install expects.
  Drag this whole pseudoregalia folder into your Steam install's Pseudoregalia folder.

Setup, once:
1. Drag the `pseudoregalia` folder from this folder directly into your Steam install's
   Pseudoregalia folder -- the one Steam created, typically
   `...\Steam\steamapps\common\Pseudoregalia\` (NOT the `pseudoregalia` subfolder already
   inside it -- drop this one ON TOP of that outer folder so the two merge).
2. Windows will ask about merging folders and replacing files -- say yes to all of it. This
   only adds/updates mod files; it won't touch or remove anything else already in your
   install (including Archipelago's own files, if installed).

Setup, once more -- where your settings live:
3. Open config.json in the MeshGhostPseudo mod folder you just installed
   (`...\Pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo\config.json`)
   and set "connect_to" to your host's address, plus "room" and "name". This is the file
   the mod's own copy of meshghost.exe reads -- NOT the config.json in the folder you
   unzipped. Once the mod is installed inside your game, that outer one is out of reach.

Setup, every time you play:
1. Launch Pseudoregalia normally. That's the whole thing -- the mod starts MeshGhost for
   you, with no window to leave open and nothing to run first. The mod loads automatically
   via UE4SS and tells MeshGhost which game it is on its own.
2. Walk around. Once a friend joins the same server in the same room, you should see their
   goat as a ghost -- correct position, facing, and movement animations.

If you want to see it working rather than take it on faith, add "show_console": true to
that config.json for a real window with live output, or read meshghost.log, which appears
in the same mod folder.

On Linux (Proton) and macOS (CrossOver), that window is shown by DEFAULT, and that's
deliberate. On Windows we've watched MeshGhost start with the game and stop with it,
including when the game crashes. Through Wine that's untested -- so rather than risk
leaving you a process you can't see and can't close, it shows itself. Close it by hand if
it's ever still there after you quit. Add "show_console": false if you've satisfied
yourself it cleans up and would rather not see it. If neither exists, the mod never got as far as starting it -- check
ue4ss\UE4SS.log, and see the antivirus note in the main README.txt.

Prefer to run it yourself? Set the environment variable MESHGHOST_NO_AUTOSTART to anything
and the mod won't start one; double-click meshghost.exe (in the folder you unzipped)
before launching the game, exactly as TEVI and Emerald do.

Two important notes specific to Pseudoregalia:
- The mod always uses local bridge port 7778, and the config.json beside it deliberately
  has no "local_game_bridge" setting -- the mod passes that port to MeshGhost itself, so
  there's only one place it can be set rather than two that could disagree. If you're
  trying to run two copies of MeshGhost on the same machine (see the main README.txt),
  that trick does not currently work for Pseudoregalia.
- You should stop seeing a friend's ghost while you're in different areas of the castle --
  if you still see one across areas, that's useful to know -- there's nowhere to report it
  yet, but don't assume it's your setup.
