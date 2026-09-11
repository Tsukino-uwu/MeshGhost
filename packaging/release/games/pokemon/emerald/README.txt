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

Running the client -- two ways, pick either:

  1. OPEN IT YOURSELF (works everywhere)
     Double-click meshghost.exe before you load the script, and close it when you
     are done.

     KEEP config.json NEXT TO IT. The client reads the config.json in its own folder,
     so if you move the exe, move config.json with it -- they travel as a pair. On its
     own the client falls back to built-in defaults (127.0.0.1:7777, your own machine)
     and never reaches your host. Keeping both in THIS folder is simplest, and it is
     also what option 2 wants.

  2. LET THE EMULATOR OPEN AND CLOSE IT (optional -- location matters)
     Put meshghost.exe in THIS folder, beside the script, and the script starts it
     with no window when you load the script and shuts it down when you close the
     emulator. The client then reads the config.json in this folder, so this game's
     settings, its meshghost.log and its replay\ folder are all separate from every
     other game's -- the same arrangement TEVI and Pseudoregalia use.

     THE MESHGHOST ROOT NO LONGER STARTS ONE (changed 2026-09-11). The script looks
     beside itself and nowhere else, so an exe left in the MeshGhost root is simply
     option 1: you start it yourself. That is the point of the change -- autostart is
     a convenience you turn on by making this copy, not something an install gets
     without being asked, and one program starting another is exactly what an
     antivirus objects to. The Lua Console prints which config.json the client read,
     every time.

     If an antivirus objects to one program starting another -- or you simply want to
     watch the client's window -- use option 1 instead, and put "autostart": false in
     this folder's config.json so the script stops trying to start one (docs\
     troubleshooting.txt explains it under "Running the client yourself instead").

Either way, the Lua Console prints what happened, including the
"connected to relay ... in room ..." line that means it worked.

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
