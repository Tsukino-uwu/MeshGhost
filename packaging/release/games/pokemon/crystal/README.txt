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

You do NOT start meshghost.exe yourself. The script finds it three folders up (in the
MeshGhost root, next to config.json), starts it with no window, and closes it again when
you close the emulator. It reads that same root config.json, so there is nothing to copy
and nothing to edit anywhere else. Set MESHGHOST_NO_AUTOSTART to anything if you would
rather run the client by hand.

What makes Crystal different from the other games here:
- The ghost is a real map object, made out of the same parts the game uses for its own
  NPCs -- so it walks with the game's own step animation and this mod draws nothing
  itself. It is solid, the same way an NPC is; you cannot walk through a friend.
- A ghost does not survive a map change or a battle, because the game rebuilds its
  objects from scratch on both. It comes back a moment later on its own.
- A ghost wears the sprite of the player it represents, read from your own cartridge.
  This needs the mod to know where your ROM keeps its sprite table, so it works on
  vanilla and is off on ROMs where that has not been measured -- there a ghost falls
  back to wearing this machine's own sprite, and the log says so on startup.

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
