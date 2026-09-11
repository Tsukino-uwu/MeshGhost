MeshGhost -- start here
========================

You need your own copy of each game.


WHAT'S IN THIS FOLDER
---------------------
  meshghost.exe         The client. It runs while you play. Copy it in beside
                        your game's mod (step 2) and the mod starts and closes
                        it for you; leave it here and you start it yourself.

  meshghost-server.exe  The server. Only the ONE person hosting needs this.

  config.json           The settings file. You will edit three lines of it.

  games\                One folder per supported game. Only your game's
                        folder matters to you, and each has its own
                        README.txt with the exact steps for that game.

  docs\                 The full instructions, as text files like this one.
                        Which of them to read is below.


SETUP
-----
1. Install your game's mod -- see games\<your game>\README.txt.

2. Copy meshghost.exe into the folder holding that game's mod, if you want
   the mod to start and stop it for you. Skip this and you start it
   yourself instead -- both are supported, and neither is a debug mode.

     TEVI            your TEVI folder, next to TEVI.exe
                     (copy config.json in with it)
     Pseudoregalia   your Pseudoregalia folder
                     (copy config.json in with it)
     Emerald         games\pokemon\emerald\, beside the script
     Crystal         games\pokemon\crystal\, beside the script

   THAT copy is the one MeshGhost reads from then on, and the config.json
   beside it is the one it uses. The two Pokemon games already have their
   config.json in place; for TEVI and Pseudoregalia copy it in with the exe.

3. Open the config.json in that folder and set three things under
   "client":

       "connect_to"  the host's address, which they will give you
       "room"        a word your whole group agrees on
       "name"        your nametag (leave empty for none)

   Keep the quotes and commas exactly as they are, and save as UTF-8.

4. Start the game. If you copied meshghost.exe in at step 2, the mod starts
   it for you; if not, start meshghost.exe yourself first.

5. Walk around. Your "it worked" signal is a line reading
   "connected to relay ... in room ...", in meshghost.log. Every game writes
   it to the same place -- meshghost.exe writes that line, not the game's mod.
   (The two Pokemon games also print to BizHawk's Lua Console, which is where
   you see whether the mod itself loaded.)


HOSTING
-------
Double-click meshghost-server.exe and leave the window open. It prints
what to forward on your router when it starts. Give your friends the
address it shows, and the "room" word.

If you cannot forward ports, docs\hosting.txt covers the alternatives.


WHAT TO READ
------------
  docs\getting-started.txt    The steps above, in full.

  docs\hosting.txt            Running the server for your group.

  docs\troubleshooting.txt    It did not work, an antivirus objected, or
                              something looks wrong.

  docs\config.txt             Every setting in config.json.
