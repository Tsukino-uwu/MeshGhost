MeshGhost -- Pokemon Crystal setup
====================================

What you need, once:
- Your own legally-obtained copy of Pokemon Crystal (Game Boy Color) and BizHawk
  (https://tasvideos.org/BizHawk).

What's in this folder:
- meshghost_crystal.lua -- the mod itself.
  lib\ -- a dependency it needs. Keep it in this same folder, next to the script.
- run_second_client.lua -- only for running TWO copies on ONE machine. See below.

Setup, every time you play:
1. Double-click meshghost.exe (three folders up, in the MeshGhost root next
   to config.json). Leave the window open.
2. Open your ROM in BizHawk.
3. In BizHawk: Tools > Lua Console, then Script > Open Script, and pick
   meshghost_crystal.lua from this folder.
4. Walk around. Once a friend joins the same server in the same room, you should see
   their character walking around your game, facing the way they face.

What makes Crystal different from the other games here:
- The ghost is a real map object, made out of the same parts the game uses for its own
  NPCs -- so it walks with the game's own step animation and this mod draws nothing
  itself. It is solid, the same way an NPC is; you cannot walk through a friend.
- A ghost does not survive a map change or a battle, because the game rebuilds its
  objects from scratch on both. It comes back a moment later on its own.
- Everyone currently looks like the same character, whatever their own game shows.
  Showing a friend's own look needs their sprite loaded into your game and that is
  not done yet.

Two copies on one machine:
- Load meshghost_crystal.lua in the first BizHawk, and run_second_client.lua in the
  second. That is the only difference -- it is a four-line file that points the second
  copy at the second client's port (7779) and then loads the same mod.
- Your second copy's config.json needs "local_game_bridge" set to that same 7779.
  See the main README.txt for running two clients.

Patched and randomized ROMs:
- Vanilla Pokemon Crystal (V1.0, the USA/Europe release) is what this is tested against.
- An Archipelago-patched ROM is RECOGNIZED but will not run yet: the mod identifies the
  ROM from its header, finds it has moved things around in memory, and stops with a
  message naming what it still needs to know. That is deliberate -- guessing at those
  addresses would write to whatever now sits there. Most of the work is done and it has
  been seen working; one value is still being confirmed.
- Any other romhack or translation is untested. The mod will say so on startup and run
  anyway, since an untested ROM is not the same as a known-wrong one. It only ever reads
  and writes the game's object memory -- it never touches your save file -- so the worst
  case is a visual mess that a map change or a reset clears.
