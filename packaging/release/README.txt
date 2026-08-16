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

Status: Pokemon Emerald is tested and working. TEVI and Pseudoregalia are both
EXPERIMENTAL. TEVI has been confirmed working with two real players (two local
instances on one machine; not yet confirmed over a network between two separate
machines). Pseudoregalia is code-complete but has not yet been tested with a
second player at all. See games\tevi\README.txt and games\pseudoregalia\README.txt.

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
     "transport" -- LEAVE THIS AS "udp" unless you have a reason not to.
               You do NOT need to know what your host is running or which
               port anything is on: your client always makes contact over
               tcp first, asks what they serve, and only then switches. If
               they don't offer udp you simply stay on tcp and everything
               still works.
               Put "quic" here instead if you want your room_code
               encrypted -- but your host has to be serving quic for that
               to happen (ask them). "tcp" keeps you on the plain, most
               predictable one. There's a full pros/cons rundown in
               "Transports -- tcp vs udp vs quic" near the bottom.
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
     "max_receive_hz_per_player" -- LEAVE THIS AT 0 UNLESS YOU KNOW YOU
               NEED IT. Caps how often you want OTHER players' positions
               sent to YOU, one at a time (see "What do Hz/ms/tickrate
               mean?" below if that's unfamiliar). 0 (the default) means
               uncapped -- you get everyone's updates as fast as the room
               sends them. Only useful if your OWN internet connection is
               slow or has a data cap and you want to trade smoothness for
               less incoming data.

               IMPORTANT: this is PER OTHER PLAYER, not a total. Setting
               this to 5 in a room of 8 people is up to 35 updates/second
               coming in, not 5 -- multiply by (however many other players
               are in your room minus you).

               This only ever affects what YOU download and what YOU see
               -- it changes nothing about what anyone else sees or what
               you send. If you do set it, valid values are 10-100;
               anything below about 10 will look stuttery/snappy unless
               you also raise "interp" above.
   Only edit the text between the quotes -- keep the quotes, colons, and
   commas exactly as they are, or the file won't parse.
   Notepad is fine for this. If you use something else, save the file as
   UTF-8 (the usual default) -- saving it as "Unicode"/UTF-16 makes it
   unreadable, and then EVERY setting in it is ignored, not just the one
   you changed. meshghost.log / meshghost-server.log say so plainly if
   that happens, so check there first if an edit seems to do nothing.
   You do NOT set which game you're playing here -- meshghost.exe figures
   that out automatically from whichever game's mod/script you load (see
   "Playing" below). Switching games just means loading a different one and
   restarting meshghost.exe -- nothing in config.json to change.
3. If you're hosting, also edit "server":
     "listen_on" -- what port to accept connections on. "0.0.0.0:7777"
               (the default) means "accept from anywhere," which is what
               you want. Only change the port number if you need to.
     "transport" -- "tcp" (the default), "udp", "quic", or a list like
               "tcp,quic" to offer more than one at once. Players find
               whatever you turn on by themselves, so you do NOT need to
               tell them which to use or what port it's on -- a player on
               the default picks up udp automatically if you serve it, and
               falls back to tcp if you don't. tcp is always served whether
               you list it or not, because that is how every client makes
               first contact. Pros/cons of each are in "Transports --
               tcp vs udp vs quic" near the bottom, along with which ports
               you need to forward for each.
     "listen_quic" -- only used if you put "quic" in "transport". It needs
               its own port number, different from "listen_on".
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
     "only_game" -- OPTIONAL. Leave as "" to keep the old behavior: your
               server hosts whatever game each player shows up with, and
               can even host two different games at once if they're using
               different room names. Set it to one game's id to run a
               dedicated single-game server -- anyone playing anything
               else is turned away as soon as they connect, with a message
               saying so. The valid ids are exactly:
                   emerald         (Pokemon Emerald)
                   tevi            (TEVI)
                   pseudoregalia   (Pseudoregalia)
               Type one of those exactly as written, all lowercase -- a
               typo here turns EVERYONE away, including you. If that
               happens, meshghost-server.log prints the value it actually
               read on startup, so you can see what it thinks you set.
               Nobody has to change anything on their end for this; their
               game announces itself automatically. IMPORTANT: same catch
               as "room_code" -- this only works if YOU (the host) are
               running the current meshghost-server.exe. An old copy
               silently ignores this setting and keeps hosting every game
               with no warning. If in doubt, re-download the latest
               release.
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
               See "How many players can I actually host?" below for what
               a given room size actually costs your connection.
     "send_hz" -- LEAVE THIS AT 20 UNLESS YOU KNOW YOU NEED IT. How many
               times per second every player in your room sends their
               position (see "What do Hz/ms/tickrate mean?" just below).
               20 (the default) is a "20 tick" room; every player already
               sends at this rate today whether you set this or not.
               Raising it makes every ghost update more often -- but it
               also multiplies every player's network usage by the same
               amount, in both directions, and YOUR machine (the host)
               pays for it worst of all (see the numbers below). Valid
               range is 10-100. A player can still choose to send SLOWER
               than this if their own connection needs it (their client's
               own setting always wins over yours if theirs is slower) --
               but nobody can send faster than what you set here.

What do Hz/ms/tickrate mean? (relevant to "send_hz" above and
"max_receive_hz_per_player" earlier)

These are three ways of writing the same number, and different people
know different ones -- if you only recognize one of these words, this is
for you:
  - Hz (hertz) = how many times per second something happens. "20 Hz"
    means 20 updates every second.
  - ms (milliseconds) = the GAP between updates, the flipped-around way
    of saying the same thing. 20 Hz = one update every 50 ms. The math:
    1000 / Hz = ms. Higher Hz means a SMALLER gap between updates, and
    vice versa -- they move in opposite directions, which is the usual
    source of confusion.
  - "Tickrate" is the word game servers usually use for this. A "64 tick"
    or "128 tick" server (Counter-Strike, Valorant, Overwatch, etc.) means
    64 Hz or 128 Hz. If you've ever tuned a game server's tickrate before,
    "send_hz" here is that same setting.
  In short: 20 Hz = 50 ms between updates = a "20 tick" room. Three
  labels for one number.

The real cost of raising send_hz -- shown per-hour, not per-second,
because the same number looks tiny per-second and adds up fast per-hour.

These are REAL MEASURED numbers, not estimates. They are measured for
PSEUDOREGALIA, deliberately: it sends the most detailed position update
of the three supported games (597 bytes per update, vs. 249 for TEVI and
206 for Pokemon Emerald), so every number below is a worst case. If
you're hosting one of the other two, your real usage is roughly a third
of what's shown here. Pick your room size off this table and a lighter
game can only surprise you in the good direction.

  YOUR OWN upload (what you personally send out -- same no matter how
  many people are in the room):
    20 Hz  (default):  about 11.7 KB/s  =  about  41 MB/hour
    100 Hz (maximum):  about 58.3 KB/s  =  about 205 MB/hour   (5x)

  YOUR OWN download (everyone else's positions coming IN to you --
  scales with how many OTHER players are in the room), at 20 Hz:
    2-player room:   about  11.7 KB/s  =  about   41 MB/hour
    4-player room:   about  35.0 KB/s  =  about  123 MB/hour
    8-player room:   about  81.6 KB/s  =  about  287 MB/hour
    16-player room:  about 174.9 KB/s  =  about  615 MB/hour
  At 100 Hz, multiply all four by 5.

  THE HOST'S upload (everyone's position, relayed to everyone else --
  this is what YOUR machine carries if you're hosting; it grows with the
  SQUARE of room size, not just the number of players), at 20 Hz:
    2-player room:   about  23.3 KB/s  =  about   82 MB/hour
    4-player room:   about 139.9 KB/s  =  about  492 MB/hour
    8-player room:   about 653.0 KB/s  =  about  2.2 GB/hour
    12-player room:  about   1.5 MB/s  =  about  5.3 GB/hour
    16-player room:  about   2.7 MB/s  =  about  9.6 GB/hour
    24-player room:  about   6.3 MB/s  =  about 22.1 GB/hour
    32-player room:  about  11.3 MB/s  =  about 39.7 GB/hour
  At 100 Hz, multiply all of these by 5 as well.

Bottom line: going from 20 to 100 multiplies EVERYONE's bandwidth by 5,
for a visual improvement that's small and gets smaller the higher you
go -- your client already smooths motion between updates ("interp"
above), so 20/second already looks smooth to begin with. If you're
hosting, look at the host row first; that's what your own machine has to
carry. Only raise this if you have a specific reason to.


How many players can I actually host? (guidance for "max_clients")

The honest answer is that YOUR UPLOAD SPEED decides this, not the
software. There's no hard limit built in -- max_clients is 8 by default
because that's a size almost any home connection can carry, not because
9 would break something.

Because the host relays everyone's position to everyone else, host
upload grows with the SQUARE of the room. Doubling the players roughly
quadruples your upload. That's why the jump from 8 to 16 costs so much
more than the jump from 2 to 4.

Here's the same host-upload numbers as above, in the units your internet
plan is sold in (megabits per second), at the default 20 Hz and for the
heaviest game:

    4 players:    about  1.2 Mbps upload
    8 players:    about  5.4 Mbps upload   (the default)
    12 players:   about 12.6 Mbps upload
    16 players:   about 22.9 Mbps upload
    24 players:   about 52.7 Mbps upload
    32 players:   about 94.8 Mbps upload

To use this: run any internet speed test, look at the UPLOAD number (not
download -- they're often very different, and upload is usually the much
smaller one), and don't plan to spend more than about half of it here.
The other half is for the game itself, voice chat, and general headroom;
a link run at 100% doesn't just get slower, it gets erratic, and ghosts
start stuttering for everyone at once.

Two things worth knowing before you raise it:

  - Raising send_hz multiplies every number above by up to 5. Raising
    BOTH send_hz and max_clients together is what actually gets people
    into trouble. Change one at a time.
  - These are network numbers only. Your own game also has to draw every
    ghost, and a 3D game drawing 15 extra characters costs real frames
    on the machines of everyone in the room, not just yours. If people
    report the game getting choppy while the network looks fine, that's
    this, and the fix is a smaller room.

If you want to find your own real ceiling rather than trusting a table,
the repo has a load-test rig that fills a room with synthetic players --
see dev-scripts/README.md.

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


Transports -- tcp vs udp vs quic
---------------------------------
"transport" in config.json picks HOW meshghost.exe talks to the server.

Whatever you pick, your client ALWAYS makes first contact over tcp, asks
the host what they serve, and only then switches. That is why you never
need to know port numbers, and why picking something your host doesn't
serve leaves you on a working tcp connection instead of failing.

If you're a PLAYER: leave it on "udp" (the default) and stop reading,
unless you specifically want your room_code encrypted -- then use "quic"
and ask your host to serve it.

If you're HOSTING: "transport" is what you actually serve, and you can
serve more than one at once. This is the only place the choice really
matters, since players find whatever you turn on by themselves.

  tcp  (what the SERVER defaults to, and always served regardless)
    + Works everywhere, no surprises.
    + The only one we can actually inspect when something goes wrong, so
      it's the easiest to get help with.
    - A lost packet holds up the positions queued behind it until it gets
      resent, so a bad connection can look "stuttery then catch up".
    - Not encrypted: your room_code travels in the clear.

  udp  (what the CLIENT defaults to)
    + Handles a bad/lossy connection better -- a dropped position is just
      skipped instead of delaying the next one, so ghosts keep moving
      smoothly instead of freezing and then snapping forward.
    + The lightest of the three -- least added data per update.
    - NOT encrypted, and unlike tcp this can never be fixed. Your
      room_code travels in the clear. If that matters, use quic instead.
    - Harder to troubleshoot.
    - On a healthy connection it is NOT faster (see the note below).

  quic
    + Same loss handling as udp, so the same benefit on a bad connection.
    + Encrypted, and very hard to spoof. The only one where your room_code
      is protected in transit.
    - Needs its OWN port ("listen_quic" on the host's side) -- it cannot
      share one with udp. That's one more port to forward.
    - Harder to troubleshoot.

"But isn't udp the fast one?"  Not quite, and this is the most common
misunderstanding: on a connection that isn't dropping packets, all three
arrive at exactly the same speed. Same route, same physics. What udp and
quic avoid is one lost packet holding up the ones behind it -- so the win
is SMOOTHNESS on a bad connection, not lower ping on a good one.

Short version:
  Playing, not hosting?           udp (the default -- just leave it)
  Want your room_code encrypted?  quic (and ask your host to serve it)
  Hosting, keep it simple?        tcp
  Hosting for a flaky group?      tcp,udp
  Hosting, privacy-conscious?     tcp,udp,quic

There is also "auto", which asks the host and takes the best on offer --
it prefers quic, then tcp, and deliberately never picks udp for you, since
choosing an unencryptable transport on someone's behalf isn't a decision a
default should make. Use it if you'd rather not think about this at all.

Hosting: "transport" accepts a list, so you can offer several at once --
"tcp,udp,quic". Players still pick a single one each, and players on
DIFFERENT transports still share a room and see each other normally.

Port forwarding, if you host over the internet: you need a rule per
transport you actually offer, and the protocol matters --
  tcp  -> forward TCP  on 7777
  udp  -> forward UDP  on 7777   (same number as tcp is fine, they don't
                                  clash -- TCP and UDP are separate)
  quic -> forward UDP  on 7780   (whatever "listen_quic" says)
A player set to a transport you haven't forwarded just sees a timeout with
nothing explaining it, so if someone can't connect, check this first.
