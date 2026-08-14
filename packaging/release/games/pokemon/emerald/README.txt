MeshGhost -- Pokemon Emerald setup
====================================

What you need, once:
- Your own legally-obtained copy of Pokemon Emerald (GBA) and BizHawk
  (https://tasvideos.org/BizHawk).

What's in this folder:
- meshghost_emerald.lua -- the mod itself.
  lib\ -- a dependency it needs. Keep it in this same folder, next to the script.

Setup, every time you play:
1. Double-click meshghost.exe (two folders up). Leave the window open.
2. Open your ROM in BizHawk.
3. In BizHawk: Tools > Lua Console, then Script > Open Script, and pick
   meshghost_emerald.lua from this folder.
4. Walk around. Once a friend joins the same server in the same room, you should see
   their character as a ghost -- correct sprite/gender, facing, and walking/running
   animation.

One note specific to Emerald:
- If you're running two copies of MeshGhost on the same machine (see the main README.txt),
  set the MESHGHOST_BRIDGE_PORT environment variable before launching the second BizHawk
  instance to match that copy's "local_game_bridge" port -- the script reads it from there,
  not from config.json.
