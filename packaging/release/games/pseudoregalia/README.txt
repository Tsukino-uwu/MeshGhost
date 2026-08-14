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
- You should stop seeing a friend's ghost while you're in different areas of the castle --
  if you still see one across areas, that's useful to know -- there's nowhere to report it
  yet, but don't assume it's your setup.
