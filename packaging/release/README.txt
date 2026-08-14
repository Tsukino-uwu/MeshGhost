MeshGhost -- setup
===================

What's in this folder:
- meshghost.exe        -- the client. EVERYONE playing runs this, whether
                            hosting or not.
- meshghost-server.exe  -- the server. Only ONE person in your group needs
                            this -- whoever is hosting the session.
- config.json            -- THE ONLY FILE YOU SHOULD NEED TO EDIT. Has a
                            "client" section (everyone edits this) and a
                            "server" section (only the host touches this).
- games\                -- one folder per supported game. Only the folder
                            for the game you're playing matters to you.

Status: Pokemon Emerald is tested and working. TEVI and Pseudoregalia are
EXPERIMENTAL -- included so they can finally be tested with a real second
player, but neither has been confirmed working over a real network yet. See
games\tevi\README.txt and games\pseudoregalia\README.txt.

Setup, once:
1. Open config.json in a text editor (Notepad is fine).
2. Under "client":
     "connect_to" -- the HOST's IP:port -- they'll give you this.
               "127.0.0.1:7777" only works if YOU are also the host, on the
               same machine.
     "room"  -- whatever your group agrees on; everyone must use the SAME
               room name to end up in the same session. This is a label,
               not a password -- it doesn't stop someone else from also
               using that name. If the host set a "room_code" (below),
               enter it here too.
     "room_code" -- only needed if your host told you they set one. Leave
               it as "" if they didn't -- most hosts won't have, since it's
               off by default. If they did set one, you must enter it
               exactly or you'll be refused.
     "name"  -- whatever you want your ghost to show as to others.
     "local_game_bridge" -- internal, on your own PC only. Leave this alone
               unless you're running two copies on the SAME machine (see
               below).
     "interp" -- how far behind real-time (e.g. "100ms", "200ms") you render
               OTHER players' ghosts, to smooth out network jitter. This is
               entirely YOUR OWN client's setting -- it doesn't affect what
               anyone else sees, and different players in the same session
               can use different values.

               Not sure? Leave it at "100ms" -- that's the default if you
               leave this out entirely, and a reasonable starting point for
               most connections.

               Rough guide if you want to tune it (not scientifically
               measured for this game, just general rules of thumb -- feel
               free to experiment):
                 "100ms"          -- default. Fine for a typical home
                                     connection playing with friends.
                 "150ms"-"250ms"  -- a rough, high-ping, or unstable
                                     connection (playing across countries,
                                     flaky wifi, etc). Ghosts look smoother
                                     but noticeably more delayed.
                 below "50ms"     -- not recommended, even on a great
                                     connection: your own client only sends
                                     its position about once every 50ms (20
                                     times/second) no matter what, so a
                                     lower value doesn't get you fresher
                                     data -- it just leaves less buffer to
                                     smooth over, and will likely look
                                     stuttery/snappy instead of smooth.
   Only edit the text between the quotes -- keep the quotes, colons, and
   commas exactly as they are, or the file won't parse.
   You do NOT set which game you're playing here -- meshghost.exe figures
   that out automatically from whichever game's mod/script you load (see
   "Playing" below). Switching games just means loading a different one and
   restarting meshghost.exe -- nothing in config.json to change.
3. If you're hosting, also edit "server":
     "listen_on" -- what port to accept connections on. "0.0.0.0:7777"
               (the default) means "accept from anywhere," which is what
               you want. Only change the port number if you need to.
     "room_code" -- OPTIONAL. Leave as "" to keep the old behavior: anyone
               who has your address can join. Set it to a word or phrase
               to require everyone to also enter that same code in their
               own config.json's "client" section before joining -- tell
               them what it is the same way you tell them your address.
               This does NOT encrypt anything -- someone who can already
               watch your network traffic could still read the code in
               transit -- it just stops a stranger who only has your
               address from getting in. IMPORTANT: this only works if
               EVERYONE (you as host, and every player) is running the
               current meshghost.exe/meshghost-server.exe -- an old copy
               silently ignores this setting and stays open with no
               warning. If in doubt, re-download the latest release.
     "max_clients" -- how many players this relay accepts in total,
               including you -- across every room, if your group ever
               uses more than one room name on the same relay at once. 8
               by default. The relay only ever sends a player's position
               to other players in that SAME room, never to a different
               room -- but you can still raise this and end up with one
               big room, and a bigger room means more network traffic for
               YOUR machine (the host) to handle, since everyone in it
               gets sent everyone else's position. Don't set this to
               something huge without expecting to actually need it.

Hosting (skip this section if you're not the host):
1. Double-click meshghost-server.exe. Leave the window open while people
   play.
2. If your friends are NOT on the same local network/VPN as you, forward
   your port (TCP) on your router to this machine, or run this on a small
   public server/VPS instead.
3. Give your friends this machine's IP address (and port, if you changed
   it) -- they'll need it for their "connect_to" setting. If you didn't set
   a "room_code", treat the address itself as the shared secret: anyone
   who has it can join.
4. To stop hosting: close the window (or Ctrl+C).

Playing, every session (everyone, including the host):
1. Double-click meshghost.exe. Leave the window open -- it should say
   "no game set -- waiting for a game to connect and say hello...". If it
   prints a warning about config.json instead, you probably broke the JSON
   syntax above -- the warning will say what's wrong.
2. Open your game and load its MeshGhost mod/script -- see games\<your
   game>\README.txt for exactly how (BizHawk Lua Console for Emerald,
   BepInEx plugin for TEVI, UE4SS mod for Pseudoregalia). Once it connects,
   the meshghost.exe window should change to say "connected to relay ... in
   room ..." -- that's your "it worked" signal.
3. Walk around. Once a friend joins the same server in the same room,
   you'll see their character as a ghost -- correct sprite/model, facing,
   and movement, tracking their real position. No shared world state:
   items, battles/fights, and story progress are all still fully
   independent per player.

Playing with two people on the SAME machine (testing/local): each instance
needs its own local_game_bridge port. Copy this whole folder a second time,
and in the second copy's config.json change "local_game_bridge" to
"127.0.0.1:7779" (must differ from the first copy's).

Something not working? Both meshghost.exe and meshghost-server.exe also
write everything they print to a log file in this same folder
(meshghost.log / meshghost-server.log), overwritten fresh each run -- if a
window closes before you can read what it said, check the log file instead.

Common things to check:
- The server window (host's machine) should show your name joining.
- "connect_to" in config.json must exactly match the host's real address --
  typos are the usual cause of "nothing happens."
- If playing over the internet (not the same network), the HOST needs their
  port forwarded -- that's their setup, not yours.
- meshghost.exe's window still says "waiting for a game to connect" after
  you loaded your game's mod/script? Double-check you loaded it from the
  right folder under games\, and that meshghost.exe was already running
  first.
