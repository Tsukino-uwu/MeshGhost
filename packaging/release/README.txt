MeshGhost -- start here
========================

MeshGhost puts your friends into your single-player game as ghosts. You see
each other move around in real time; everything else stays separate. No shared
items, enemies, health or story progress -- if a friend beats a boss, it is
still alive in your world. Your save is never touched and no ROM is patched.

You can also record yourself and play it back as a ghost beside you, with no
server and nobody else involved.


WHAT'S IN THIS FOLDER
---------------------
  meshghost.exe         The client. It runs quietly while you play.
                        YOU DO NOT OPEN THIS YOURSELF -- your game's mod
                        starts it and closes it for you.

  meshghost-server.exe  The server. Only the ONE person hosting needs this.

  config.json           The settings file. You will edit three lines of it.

  games\                One folder per supported game. Only your game's
                        folder matters to you, and each has its own
                        README.txt with the exact steps for that game.

  docs\                 The full instructions, as text files like this one.
                        Which of them to read is below.


WHAT TO READ
------------
  docs\getting-started.txt    <- START HERE. Everything a player does, from
                                 unzipping this folder to seeing a friend's
                                 ghost.

  docs\hosting.txt              Only if you are the one running the server
                                 for your group. Short version at the top,
                                 the detail below it.

  docs\troubleshooting.txt      It did not work, an antivirus objected, or
                                 something looks wrong.

  docs\config.txt               Every setting in config.json: what it does,
                                 its shipped value, which program reads it.

Everything else in docs\ is for people who want to look deeper -- how the
networking actually works, what is encrypted, how to audit the code, and how
to put MeshGhost into a game of your own.


THE SHORT VERSION
-----------------
1. Install your game's mod -- see games\<your game>\README.txt.

   Then copy meshghost.exe into the folder holding that game's mod -- the
   game's own folder for TEVI and Pseudoregalia (config.json goes with it),
   or games\pokemon\<game>\ for the two Pokemon games (config.json is
   already there). THAT copy is the one MeshGhost reads from then on.

   TEVI and Pseudoregalia require this. The two Pokemon games do not: they
   fall back to this folder if you skip it, and only lose the per-game
   separation by doing so.

2. Open the config.json your game actually reads and set three things in
   the "client" section:

       "connect_to"  the host's address, which they will give you
       "room"        a word your whole group agrees on
       "name"        your nametag (leave empty for none)

   Keep the quotes and commas exactly as they are, and save as plain UTF-8.

3. Start the game. That is all -- there is nothing to launch first, nothing
   to leave open, and no order to get right.

4. Walk around. Your "it worked" signal is a line reading
   "connected to relay ... in room ...", in BizHawk's Lua Console for the
   two Pokemon games, or in meshghost.log for TEVI and Pseudoregalia.

If you are HOSTING: double-click meshghost-server.exe, leave the window
open, and make your machine reachable -- it prints exactly what to forward
when it starts. If you cannot forward ports, docs\hosting.txt covers the
alternatives. Then give your friends your address.


STATUS OF EACH GAME
-------------------
  Pokemon Emerald    tested and working
  Pokemon Crystal    tested and working
  TEVI               EXPERIMENTAL -- confirmed with two real players, but as
                     two instances on one machine, not yet over a network
                     between two separate machines
  Pseudoregalia      EXPERIMENTAL -- confirmed with two real players on two
                     separate machines; still experimental because that is
                     one pair of machines rather than broad testing

See games\tevi\README.txt and games\pseudoregalia\README.txt.


Bring your own legally-obtained copy of each game. No ROMs or game assets
are shipped here.
