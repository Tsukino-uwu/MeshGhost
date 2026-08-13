MeshGhost -- Pseudoregalia setup
=================================

STATUS: EXPERIMENTAL. This mod is code-complete -- ghost spawning, positioning, facing,
and movement animations have all been confirmed working live, solo -- but it has NOT yet
been tested with a real second player over a real network. If something doesn't work with
two players, that's useful information -- there's nowhere to report it yet, but don't
assume it's your setup.

What you need, once:
- Your own legally-obtained copy of Pseudoregalia.
- That's it. UE4SS (v3.0.1 Beta, exact commit 733e5969) is included in this folder --
  you do not need to find or install it separately. See "Setup, once" below, and
  the main project's agent_docs/licensing.md for why this is bundled (MIT-licensed,
  redistributed with its own LICENSE included) when other games' mod loaders aren't.

What's in this folder:
- pseudoregalia\ -- a single folder that mirrors your actual Pseudoregalia install's own
  layout (pseudoregalia\Binaries\Win64\...), the same way the Archipelago randomizer's own
  download works. It has everything: the UE4SS mod loader (built from the exact RE-UE4SS
  commit this project targets) and the MeshGhostPseudo mod itself, already in the right
  places inside it.

Setup, once:
1. Drag the `pseudoregalia` folder from this folder directly into your Steam install's
   Pseudoregalia folder -- the one Steam created, typically
   `...\Steam\steamapps\common\Pseudoregalia\` (NOT the `pseudoregalia` subfolder already
   inside it -- drop this one ON TOP of that outer folder so the two merge).
2. Windows will ask about merging folders and replacing files -- say yes to all of it. This
   only adds/updates UE4SS and MeshGhostPseudo; it won't touch or remove anything else
   already in your install (including Archipelago's own files, if installed).

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
- Cross-area filtering (not seeing a friend's ghost when you're in different areas of the
  castle) was fixed game-wide on 2026-08-13, but that fix hasn't specifically been watched
  live in Pseudoregalia yet (only in TEVI). If you do see a ghost across areas, that's
  useful to know -- there's nowhere to report it yet, but don't assume it's your setup.
