This folder intentionally contains only MeshGhostPseudo.

MeshGhost ships the bare minimum needed to run its own mod and nothing else.

Two things are deliberately ABSENT, and both matter if you use other mods:

  mods.txt / mods.json
      NOT shipped, on purpose. UE4SS treats both as optional, and MeshGhostPseudo
      does not need an entry in either -- it is a C++ mod, and UE4SS discovers
      those by scanning for a folder containing "dlls", independent of the lists.
      Shipping our own copies would OVERWRITE yours when this folder is dragged
      in, silently unlisting every Lua or Blueprint mod you already had (an
      Archipelago randomiser, for instance). Your existing lists are left exactly
      as they are, and you do not need to add MeshGhost to them.

  UE4SS's stock Lua mods
      NOT shipped either -- a cheat manager, a console, console commands, keybind
      hooks, an actor dumper, a line-trace tool and a profiler ship alongside the
      UE4SS runtime, and none are used by this adapter. Installing a visual-only
      ghost overlay should not add a cheat menu or a debug console to your game.
      If you want any of them, install them yourself from RE-UE4SS.

Load order relative to other mods is therefore not something MeshGhost controls
or needs to: mods.txt load order applies only to mods listed in it.
