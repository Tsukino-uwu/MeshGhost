MeshGhost -- Pokemon Crystal setup
====================================

What you need, once:
- Your own legally-obtained copy of Pokemon Crystal (Game Boy Color) and BizHawk
  (https://tasvideos.org/BizHawk).

What's in this folder:
- meshghost_crystal.lua -- the mod itself.
  lib\ -- a dependency it needs. Keep it in this same folder, next to the script.

Setup, every time you play:
1. Open your ROM in BizHawk.
2. In BizHawk: Tools > Lua Console, then Script > Open Script, and pick
   meshghost_crystal.lua from this folder.
3. Walk around. Once a friend joins the same server in the same room, you should see
   their character walking around your game, facing the way they face.

Running the client -- two ways, pick either:

  1. OPEN IT YOURSELF (works everywhere)
     Double-click meshghost.exe before you load the script, and close it when you
     are done.

     KEEP config.json NEXT TO IT. The client reads the config.json in its own folder,
     so if you move the exe, move config.json with it -- they travel as a pair. On its
     own the client falls back to built-in defaults (127.0.0.1:7777, your own machine)
     and never reaches your host. Leaving both in the MeshGhost root is simplest, and
     it is also what option 2 needs.

  2. LET THE EMULATOR OPEN AND CLOSE IT (optional -- location DOES matter)
     Leave meshghost.exe in the MeshGhost root, three folders up from this one, and
     the script finds it there by itself: it starts it with no window when you load
     the script and shuts it down when you close the emulator. That folder is the
     BizHawk equivalent of a mod folder -- it is where the script looks, and the only
     place this works from. The client reads the config.json in THIS folder, next to
     the script, so this game's settings are separate from every other game's. (If
     this folder has no config.json, it reads the one next to meshghost.exe instead,
     and the Lua Console says which.)

     If an antivirus objects to one program starting another -- or you simply want to
     watch the client's window -- use option 1 instead, and put "autostart": false in
     this folder's config.json so the script stops trying to start one (the main README
     in the folder you unzipped explains it under "Turning autostart off").

Either way, the Lua Console prints what happened, including the
"connected to relay ... in room ..." line that means it worked.

Two copies on one machine:
- Nothing to set up. Each BizHawk instance walks 127.0.0.1:7778-7785 for a free bridge
  port and starts its own client on the one it finds, so a second emulator just works --
  same as Emerald. MESHGHOST_BRIDGE_PORT still pins an exact port if you need one for
  testing.

Patched and randomized ROMs:
- Vanilla Pokemon Crystal (V1.0, the USA/Europe release) is what this is tested against.
- An Archipelago-patched ROM is identified from its header and runs on its own separately
  measured set of addresses -- none of them derived from vanilla's, because on this patch
  three separate attempts to do that were wrong. Every address it needs has now been
  measured; a missing one is still a refusal to run rather than a guess. It has had far
  less play than vanilla, and it is tied to the Archipelago Crystal base patch it was
  measured against, so a future update to that world could move things again. Showing a
  friend's own sprite is off on this ROM -- that address has not been measured here.
- Any other romhack or translation is untested. The mod will say so on startup and run
  anyway, since an untested ROM is not the same as a known-wrong one. It only ever reads
  and writes the game's object memory -- it never touches your save file -- so the worst
  case is a visual mess that a map change or a reset clears.
