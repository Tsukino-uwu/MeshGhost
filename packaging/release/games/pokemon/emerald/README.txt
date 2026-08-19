MeshGhost -- Pokemon Emerald setup
====================================

What you need, once:
- Your own legally-obtained copy of Pokemon Emerald (GBA) and BizHawk
  (https://tasvideos.org/BizHawk).

What's in this folder:
- meshghost_emerald.lua -- the mod itself.
  lib\ -- a dependency it needs. Keep it in this same folder, next to the script.

Setup, every time you play:
1. Open your ROM in BizHawk.
2. In BizHawk: Tools > Lua Console, then Script > Open Script, and pick
   meshghost_emerald.lua from this folder.
3. Walk around. Once a friend joins the same server in the same room, you should see
   their character as a ghost -- correct sprite/gender, facing, and walking/running
   animation.

You do NOT start meshghost.exe yourself. The script finds it three folders up (in the
MeshGhost root, next to config.json), starts it with no window, and closes it again when
you close the emulator. It reads that same root config.json, so there is nothing to copy
and nothing to edit anywhere else. The Lua Console prints what it did, including the
"connected to relay ... in room ..." line that means it worked.

If you would rather run the client yourself -- an antivirus that objects to one program
starting another, or you want to watch its window -- set the environment variable
MESHGHOST_NO_AUTOSTART to anything and double-click meshghost.exe before loading the script.

Two copies on one machine:
- Nothing to set up. Each BizHawk instance walks 127.0.0.1:7778-7785 for a free bridge
  port and starts its own client on the one it finds, so a second emulator just works.
  MESHGHOST_BRIDGE_PORT still pins an exact port if you need one for testing.

Patched and randomized ROMs:
- Vanilla Pokemon Emerald is what this is tested against.
- An Archipelago-patched ROM works: the patch relocates the memory the mod reads, and the
  mod detects that at startup and adjusts. This is tied to the Archipelago Emerald base
  patch it was measured against, so a future update to that world could move things again.
- Any other romhack or translation is untested. The mod only ever reads and writes the
  game's object memory -- it never touches your save file.
