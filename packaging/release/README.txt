MeshGhost -- setup
===================

What's in this folder:
- meshghost.exe        -- the client. EVERYONE playing runs this, whether
                            hosting or not.
- meshghost-server.exe  -- the server. Only ONE person in your group needs
                            this -- whoever is hosting the session.
- run-client.bat        -- run this to play. Don't edit it directly.
- run-server.bat        -- the host runs this too, alongside run-client.bat.
- config.json            -- THE ONLY FILE YOU SHOULD NEED TO EDIT. Has a
                            "client" section (everyone edits this) and a
                            "server" section (only the host touches this).
- games\                -- one folder per supported game. Only the folder
                            for the game you're playing matters to you.

Status: Pokemon Emerald is tested and working. TEVI is EXPERIMENTAL --
included so it can finally be tested with a real second player, but it has
not been confirmed working over a real network yet. See games\tevi\README.txt.

Setup, once:
1. Open config.json in a text editor (Notepad is fine).
2. Under "client":
     "connect_to" -- the HOST's IP:port -- they'll give you this.
               "127.0.0.1:7777" only works if YOU are also the host, on the
               same machine.
     "room"  -- whatever your group agrees on; everyone must use the SAME
               room name to end up in the same session. This is NOT a
               password -- there is no real authentication yet. Treat the
               host's address itself as the secret: only give it to people
               you trust.
     "name"  -- whatever you want your ghost to show as to others.
     "local_game_bridge" -- internal, on your own PC only. Leave this alone
               unless you're running two copies on the SAME machine (see
               below).
   Only edit the text between the quotes -- keep the quotes, colons, and
   commas exactly as they are, or the file won't parse.
   You do NOT set which game you're playing here -- run-client.bat figures
   that out automatically from whichever game's mod/script you load (see
   "Playing" below). Switching games just means loading a different one and
   restarting run-client.bat -- nothing in config.json to change.
3. If you're hosting, also edit "server":
     "listen_on" -- what port to accept connections on. "0.0.0.0:7777"
               (the default) means "accept from anywhere," which is what
               you want. Only change the port number if you need to.

Hosting (skip this section if you're not the host):
1. Run run-server.bat. Leave the window open while people play.
2. If your friends are NOT on the same local network/VPN as you, forward
   your port (TCP) on your router to this machine, or run this on a small
   public server/VPS instead.
3. Give your friends this machine's IP address (and port, if you changed
   it) -- they'll need it for their "connect_to" setting. Treat this like a
   shared secret: there is no password system yet, so anyone with the
   address can join.
4. To stop hosting: close the window (or Ctrl+C).

Playing, every session (everyone, including the host):
1. Double-click run-client.bat. Leave the window open -- it should say
   "no game set -- waiting for a game to connect and say hello...". If it
   prints a warning about config.json instead, you probably broke the JSON
   syntax above -- the warning will say what's wrong.
2. Open your game and load its MeshGhost mod/script -- see games\<your
   game>\README.txt for exactly how (BizHawk Lua Console for Emerald,
   BepInEx plugin for TEVI). Once it connects, the run-client.bat window
   should change to say "connected to relay ... in room ..." -- that's your
   "it worked" signal.
3. Walk around. Once a friend joins the same server in the same room,
   you'll see their character as a ghost -- correct sprite/model, facing,
   and movement, tracking their real position. No shared world state:
   items, battles/fights, and story progress are all still fully
   independent per player.

Playing with two people on the SAME machine (testing/local): each instance
needs its own local_game_bridge port. Copy this whole folder a second time,
and in the second copy's config.json change "local_game_bridge" to
"127.0.0.1:7779" (must differ from the first copy's).

Something not working? Common things to check:
- The server window (host's machine) should show your name joining.
- "connect_to" in config.json must exactly match the host's real address --
  typos are the usual cause of "nothing happens."
- If playing over the internet (not the same network), the HOST needs their
  port forwarded -- that's their setup, not yours.
- run-client.bat's window still says "waiting for a game to connect" after
  you loaded your game's mod/script? Double-check you loaded it from the
  right folder under games\, and that run-client.bat was already running
  first.
