MeshGhost -- setup
===================

What's in this folder:
- meshghost.exe        -- the client. Every player needs it running while
                            they play. You can open it yourself, or have
                            your game's mod open and close it for you --
                            see "Two ways to run the client" below.
- meshghost-server.exe  -- the server. Only ONE person in your group needs
                            this -- whoever is hosting the session.
- config.json            -- THE ONLY FILE YOU SHOULD NEED TO EDIT. Has a
                            Every key, its shipped value and what it does: docs/config.md in the
                            repository (the walkthrough below covers the ones you will touch).
                            "client" section (everyone edits this) and a
                            "server" section (only the host touches this).
- games\                -- one folder per supported game. Only the folder
                            for the game you're playing matters to you.

Status: Pokemon Emerald and Pokemon Crystal are tested and working. TEVI and
Pseudoregalia are both EXPERIMENTAL. TEVI has been confirmed working with two
real players, but as two local instances on one machine -- not yet over a
network between two separate machines. Pseudoregalia HAS been confirmed with
two real players on two separate machines, and is still marked experimental
because that is one session on one pair of machines rather than broad testing.
See games\tevi\README.txt and games\pseudoregalia\README.txt.

Two ways to run the client -- pick either:

  1. OPEN IT YOURSELF (works everywhere)
     Double-click meshghost.exe before you start the game, and close it when
     you are done.

     KEEP config.json NEXT TO IT. The client reads config.json from the folder
     it is run from -- which, when you double-click it, is the folder it sits
     in -- so if you move the exe somewhere else, move config.json with it.
     They travel as a pair. On its own, the client falls back to built-in
     defaults (it will try 127.0.0.1:7777, i.e. your own machine) and quietly
     fail to reach your host. Simplest is to leave both here in the root
     folder, which is already set up that way.

  2. LET THE GAME OPEN AND CLOSE IT (optional -- location DOES matter)
     Put meshghost.exe in the game's mod folder and the mod will start it
     hidden when you launch the game and shut it down when you quit. Nothing
     to open and nothing to remember. Each game's README in games\ says
     exactly which folder, and it is the only thing that has to be in a
     particular place.

     IF THIS TRIPS YOUR ANTIVIRUS, USE OPTION 1. A game launching a second
     program is a shape antivirus software watches for, and some will block
     it or quarantine meshghost.exe. That is not a fault to work around and
     nothing is wrong with your install -- just open the client yourself
     instead. Option 1 does exactly the same job; the only thing you lose is
     not having to open and close it yourself.
     There is also a switch that tells the mods to stop trying, so you do
     not have to uninstall anything -- see "The MESHGHOST_NO_AUTOSTART
     switch" below.

     The pairing rule applies here too: a copy in a mod folder reads the
     config.json next to IT, not this one, so that is the file you edit for
     your host's address.

The MESHGHOST_NO_AUTOSTART switch (only if you want it):

  WHAT IT IS. An environment variable -- a named setting you give to Windows
  itself rather than a line in any of MeshGhost's files. Programs can read it
  when they start.

  WHAT IT DOES. Every game's mod checks for it before starting the client. If
  it is set, the mod does not start anything: it just uses whichever client is
  already running, and never touches meshghost.exe. Nothing else changes --
  ghosts, config and everything else behave exactly the same.

  WHEN YOU WANT IT. When your antivirus objects to the game launching the
  client, when you want to watch the client's window, or when you want to
  start the client yourself for any other reason. It is a supported way to
  run MeshGhost, not a debug setting.

  YOU MAY NOT NEED IT AT ALL. For TEVI and Pseudoregalia, the mod only starts
  the client because you copied meshghost.exe into the mod folder -- do not
  copy it in (or take it out again) and there is nothing to switch off. The
  switch matters most for the two Pokemon games, where the script looks for
  the client in the MeshGhost root and finds it whether you want it to or not.

  HOW TO SET IT ON WINDOWS. Press Start, type "environment variables", and
  choose "Edit the system environment variables", then "Environment
  Variables...". Under "User variables", click "New...", enter
  MESHGHOST_NO_AUTOSTART as the name and 1 as the value, and click OK. Any
  value works -- the mods only check whether it exists. Start the game after
  that, since programs read it when they launch.

  TO UNDO IT, delete that entry the same way, and the mods go back to starting
  the client for you.

Windows, Linux and macOS:

  The CLIENT and the SERVER are built for all three, and the Linux and macOS
  builds are their own downloads on the release page (this zip is the Windows
  one). They are the same programs, not a lesser port -- a Linux or macOS host
  runs the server just as well as a Windows one, and it is a perfectly good
  choice for a server that stays up.

  Mix freely. The client and server do not care what the other end is running:
  a Windows player, a Linux player and a macOS host are one ordinary session.

  The GAMES are the part that cannot promise the same, because a mod is written
  against the game as it ships -- and these ship for Windows. If you play on
  Linux or macOS you are already running the game through Proton or Wine, and
  the Windows client runs there alongside it the same way, so it is expected to
  work; it just is not something every game and every setup can be promised in
  advance.

  Two practical notes if you are on Proton or Wine:
  - Running the client YOURSELF (option 1) is the more predictable choice
    there, since it does not depend on the game being able to launch a second
    program from inside the prefix.
  - A native Linux or macOS SERVER has no game involved at all, so it carries
    none of this uncertainty. If you are hosting, that is the easy part.

Either way the client must be running while you play; the only difference is
who starts it, and whether the exe has to sit somewhere specific.

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
     "name"  -- whatever you want your ghost to show as to others, as a
               floating nametag (in games whose mod draws one). Empty --
               the default -- means no nametag at all. Capped at 24
               characters and cleaned up by the server either way.
     "name_color" -- optional colour for that nametag, as "#RRGGBB"
               (e.g. "#00c8ff"). Leave "" for a plain name with no
               coloured box behind it.
     "ghost_collision" -- whether other players' ghosts can be solid in
               YOUR game -- bumped into, stood on, in the way. "enabled"
               (the default) accepts whatever the host chose. "disabled"
               turns it off for you no matter what the host set, which is
               the one thing this setting can do that theirs can't: a host
               can take collision away from everyone, but cannot force it
               on you. Whether a ghost was ever solid in the first place
               depends on the game -- see the note at the end of this file.
     "tls"   -- LEAVE THIS AS "auto". It encrypts the first contact your
               client makes with the host, which is the part that carries
               your room_code. "auto" uses encryption whenever the host
               supports it and still connects to hosts that don't (saying
               so in meshghost.log). "required" refuses to talk to a host
               that can't encrypt -- stricter, but a friend on an older
               version then can't host for you. "off" is plaintext.
     "tls_fingerprint" -- leave empty unless your host gave you a long
               string of letters and numbers. Encryption on its own hides
               your traffic from anyone watching; it does not prove the
               server you reached is really your friend's. Pasting the
               fingerprint they read out of their own server window is
               what proves that. Note it CHANGES every time they restart
               their server, so you'd need the new one each time -- which
               is why it's optional and off by default.
     "transport" -- LEAVE THIS AS "auto" unless you have a reason not to.
               "auto" takes the best your host offers, preferring "quic",
               which is the only one that ENCRYPTS your session (including
               your room_code). It never picks "udp" on its own, because
               udp cannot be encrypted at all.
               "connect_to" above is still the only address you need -- and
               it does need the port on the end, as shown. What you do NOT
               need is to know which transports your host runs, or which
               ports they use for them: your client always makes
               contact on that one address over tcp first, asks what they
               serve, and only then switches. If they offer nothing better
               you simply stay on tcp and everything still works.
               Put "quic" here instead if you want your room_code
               encrypted -- but your host has to be serving quic for that
               to happen (ask them). "tcp" keeps you on the plain, most
               predictable one. There's a full pros/cons rundown in
               "Transports -- tcp vs udp vs quic" near the bottom.
     "local_game_bridge" -- internal, on your own PC only. Leave this
               alone. Emerald and Crystal pick a free port by themselves,
               and TEVI and Pseudoregalia are told theirs by their own mod,
               so nothing reads this in normal play (see "two people on the
               SAME machine" below).
     "interp" -- how far behind real-time (e.g. "250ms", "150ms") you render
               OTHER players' ghosts, to smooth out network jitter. This is
               entirely YOUR OWN client's setting -- it doesn't affect what
               anyone else sees, and different players in the same session
               can use different values.

               Not sure? Leave it at "250ms" -- that's the default if you
               leave this out entirely, and it is a MEASURED value rather
               than a guess: with both a ghost and the real character on
               screen together, 100ms visibly stuttered an emulated game's
               ghost while 250ms did not (2026-08-19). The cost is that a
               ghost is drawn a quarter-second behind where that player
               really is -- a little over one tile at walking pace.

               Rough guide if you want to tune it (not scientifically
               measured for this game, just general rules of thumb -- feel
               free to experiment):
                 "250ms"          -- default, and what smooth motion was
                                     measured at. Fine for a typical home
                                     connection playing with friends, and
                                     for a rough one too.
                 "300ms"-"400ms"  -- a badly unstable connection (flaky
                                     wifi, playing across the world).
                                     Smoother still, and visibly delayed.
                 "100ms"-"150ms"  -- if you would rather have ghosts closer
                                     to where players really are and can
                                     live with less smooth movement. On a
                                     tile-based game (Pokemon) this is where
                                     stutter starts to show, because each
                                     step is a discrete hop rather than a
                                     smooth slide.
                 below "70ms"     -- not recommended, even on a great
                                     connection: your own client only sends
                                     its position about once every 67ms (15
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
     The config.json inside a game's mod folder may carry a few more keys
     ("keepalive", "curve", "extrapolate", "predict") -- rendering knobs
     already tuned per game. Leave them as shipped; each one's own
     _comment line in the file says what it does.
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
     "tls"   -- "auto" (the default) encrypts tcp connections for players
               whose client asks for it, while still accepting ones that
               don't -- including plain tools you might use to test. This
               matters even though quic is already encrypted: EVERY player
               makes first contact over tcp, and that is where their
               room_code is sent. "required" refuses unencrypted players
               outright; "off" is plaintext.
               When this is on, your server window prints a "tls
               certificate fingerprint:" line at startup. That string is
               how a player can verify they reached YOUR server and not
               someone pretending -- send it to them some other way (chat,
               not through the server) and they put it in
               "tls_fingerprint". It changes every restart. Nobody has to
               do this; without it the traffic is still encrypted, just
               not proven to be yours.
     "transport" -- "tcp,quic" (the default), or "tcp", "udp", "quic", or
               any list of them. The default serves quic alongside tcp so
               your players get an ENCRYPTED session without anyone doing
               anything, and both sit on the SAME port number -- so you
               forward one number, 7777, for both TCP and UDP (they are
               separate rules on most routers). Players find whatever you
               turn on by themselves, so you do NOT need to tell them which
               to use -- a player on the default picks up quic
               automatically, and falls back to tcp if you don't serve it.
               tcp is always served whether you list it or not, because
               that is how every client makes first contact.
               Adding "udp" is the one case that needs more: udp takes the
               same UDP port quic wants, so you must also set
               "listen_udp" (it defaults to 7780) and forward that too --
               quic keeps the shared port, because it is served by default
               and plain udp is not.
               The server refuses to start and tells you if you forget.
               Pros/cons of each are in "Transports -- tcp vs udp vs quic"
               near the bottom, along with which ports you need to forward
               for each.
     "listen_quic" -- leave it as "" (the default). quic then shares
               "listen_on"'s port number, so hosting stays one number to
               forward. It keeps that number even when plain "udp" is
               served too: udp is the one that moves aside.
     "listen_udp" -- leave it as "" (the default) unless you serve plain
               "udp". With quic served as well it moves itself to 7780,
               because the two cannot share a udp port and quic is the
               one everybody gets by default. Set it to place udp
               yourself, and forward whatever you choose.
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
                   crystal         (Pokemon Crystal)
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
     "ghost_collision" -- whether ghosts may be solid for players in your
               rooms. "enabled" (the default) leaves each game to its own
               behavior. "disabled" turns it off for EVERYONE in every
               room, which is what you want if a crowd keeps blocking
               people in doorways or you'd rather ghosts were purely
               something you look at. Players can each turn it off for
               themselves as well; they cannot turn it back on if you
               turned it off. Your server prints which one it read on
               startup. See the note at the end of this file for what it
               actually does per game.
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
     "send_hz" -- LEAVE THIS AT 15 UNLESS YOU KNOW YOU NEED IT. How many
               times per second every player in your room sends their
               position (see "What do Hz/ms/tickrate mean?" just below).
               15 (the default) is a "15 tick" room; every player already
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
  - Hz (hertz) = how many times per second something happens. "15 Hz"
    means 15 updates every second.
  - ms (milliseconds) = the GAP between updates, the flipped-around way
    of saying the same thing. 15 Hz = one update every ~67 ms. The math:
    1000 / Hz = ms. Higher Hz means a SMALLER gap between updates, and
    vice versa -- they move in opposite directions, which is the usual
    source of confusion.
  - "Tickrate" is the word game servers usually use for this. A "64 tick"
    or "128 tick" server (Counter-Strike, Valorant, Overwatch, etc.) means
    64 Hz or 128 Hz. If you've ever tuned a game server's tickrate before,
    "send_hz" here is that same setting.
  In short: 15 Hz = ~67 ms between updates = a "15 tick" room. Three
  labels for one number.

The real cost of raising send_hz -- shown per-hour, not per-second,
because the same number looks tiny per-second and adds up fast per-hour.

These come from real measurements rather than guesswork, but treat them
as the right ballpark rather than exact to the byte. They were measured
for PSEUDOREGALIA, deliberately: it sends the most detailed position
update of the supported games (597 bytes per update when last measured,
against 249 for TEVI and 206 for Pokemon Emerald; Pokemon Crystal sends
less than Emerald). If you're hosting one of the other three, your real
usage is roughly a third of what's shown here or less. Pseudoregalia's
own update has grown a little since that measurement, so if you host
that one specifically, treat the table as a floor and leave headroom
rather than planning to the last megabyte.

  YOUR OWN upload (what you personally send out -- same no matter how
  many people are in the room):
    15 Hz  (default):  about  8.8 KB/s  =  about  31 MB/hour
    100 Hz (maximum):  about 58.3 KB/s  =  about 205 MB/hour  (6.7x)

  YOUR OWN download (everyone else's positions coming IN to you --
  scales with how many OTHER players are in the room), at 15 Hz:
    2-player room:   about   8.8 KB/s  =  about   31 MB/hour
    4-player room:   about  26.3 KB/s  =  about   92 MB/hour
    8-player room:   about  61.2 KB/s  =  about  215 MB/hour
    16-player room:  about 131.2 KB/s  =  about  461 MB/hour
  At 100 Hz, multiply all four by 6.7.

  THE HOST'S upload (everyone's position, relayed to everyone else --
  this is what YOUR machine carries if you're hosting; it grows with the
  SQUARE of room size, not just the number of players), at 15 Hz:
    2-player room:   about  17.5 KB/s  =  about   61 MB/hour
    4-player room:   about 104.9 KB/s  =  about  369 MB/hour
    8-player room:   about 489.8 KB/s  =  about  1.7 GB/hour
    12-player room:  about   1.1 MB/s  =  about  4.0 GB/hour
    16-player room:  about   2.0 MB/s  =  about  7.2 GB/hour
    24-player room:  about   4.7 MB/s  =  about 16.6 GB/hour
    32-player room:  about   8.5 MB/s  =  about 29.8 GB/hour
  At 100 Hz, multiply all of these by 6.7 as well.

Bottom line: going from 15 to 100 multiplies EVERYONE's bandwidth by
nearly 7, for a visual improvement that's small and gets smaller the
higher you go -- your client already smooths motion between updates
("interp" above), so 15/second already looks smooth to begin with. That
is measured, not assumed: in a blind test where the rate was hidden from
the person watching, 15 and 20 were indistinguishable, and the stutter a
watcher can actually see only starts appearing below about 10. If you're
hosting, look at the host row first; that's what your own machine has to
carry. Only raise this if you have a specific reason to.


How many players can I actually host? (guidance for "max_clients")

The honest answer is that YOUR UPLOAD SPEED decides this, not the
software. There's no hard limit built in -- max_clients is 8 by default
because that's a size almost any home connection can carry, not because
9 would break something. The server is deliberately not the thing that
caps a session: raise it as far as your uplink and your game are happy
with. What actually runs out first is your upload (the table below) and
then the game itself having to draw that many extra characters -- never
the server refusing on principle.

Because the host relays everyone's position to everyone else, host
upload grows with the SQUARE of the room. Doubling the players roughly
quadruples your upload. That's why the jump from 8 to 16 costs so much
more than the jump from 2 to 4.

Here's the same host-upload numbers as above, in the units your internet
plan is sold in (megabits per second), at the default 15 Hz and for the
heaviest game:

    4 players:    about  0.9 Mbps upload
    8 players:    about  4.1 Mbps upload   (the default)
    12 players:   about  9.5 Mbps upload
    16 players:   about 17.2 Mbps upload
    24 players:   about 39.5 Mbps upload
    32 players:   about 71.1 Mbps upload

To use this: run any internet speed test, look at the UPLOAD number (not
download -- they're often very different, and upload is usually the much
smaller one), and don't plan to spend more than about half of it here.
The other half is for the game itself, voice chat, and general headroom;
a link run at 100% doesn't just get slower, it gets erratic, and ghosts
start stuttering for everyone at once.

Two things worth knowing before you raise it:

  - Raising send_hz multiplies every number above by up to 6.7. Raising
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
   your port on your router to this machine -- on BOTH TCP and UDP. Two
   rules, one number: the default "tcp,quic" makes first contact over TCP
   and then runs the session over quic, which rides on UDP. Or run this on
   a small public server/VPS instead.
3. Give your friends this machine's IP address (and port, if you changed
   it) -- they'll need it for their "connect_to" setting. If you didn't set
   a "room_code", treat the address itself as the shared secret: anyone
   who has it can join.
4. To stop hosting: close the window (or Ctrl+C).

Playing, every session (everyone, including the host):
1. Just start the game. ALL FOUR mods start MeshGhost for you, with no
   window -- there is nothing to run first and nothing to leave open --
   and close it again when you quit. There is no order to get right.

   Pseudoregalia and TEVI install their mod INTO the game, so they each
   need the one-time copy of meshghost.exe into that game's mod folder,
   described in games\<your game>\README.txt. Their settings then live in
   that same mod folder's config.json, NOT the config.json next to this
   README: once you drag the mod into your game, that's the copy it reads.

   Emerald and Crystal run from this folder. The script finds
   meshghost.exe and config.json right here on its own, so there is
   nothing to copy and nothing to edit anywhere else.
2. Open your game and load its MeshGhost mod/script -- see games\<your
   game>\README.txt for exactly how (BizHawk Lua Console for Emerald and
   Crystal; BepInEx for TEVI and UE4SS for Pseudoregalia, both of which
   load themselves). Your "it worked" signal is a "connected to relay ...
   in room ..." line: in BizHawk's Lua Console for Emerald and Crystal,
   and in meshghost.log beside the mod for TEVI and Pseudoregalia. If the
   log warns about config.json instead, you probably broke the JSON syntax
   above -- the warning will say what's wrong.

   Prefer to run the client yourself (an antivirus that objects to one
   program starting another, or you just want to watch its window)? Set
   the MESHGHOST_NO_AUTOSTART switch -- explained under "The
   MESHGHOST_NO_AUTOSTART switch" above, including how to set it -- and
   double-click meshghost.exe before starting the game as before. That
   path is unchanged and fully supported in all four games.
3. Walk around. Once a friend joins the same server in the same room,
   you'll see their character as a ghost -- correct sprite/model, facing,
   and movement, tracking their real position. No shared world state:
   items, battles/fights, and story progress are all still fully
   independent per player.

Playing with two people on the SAME machine (testing/local): each copy
needs its own local bridge port, and how you get one depends on the game.

  Emerald and Crystal: nothing to do. Each BizHawk instance walks
  127.0.0.1:7778-7785 looking for a port nobody has taken, so a second
  emulator finds its own and starts its own client automatically.

  TEVI: the port lives in BepInEx's own config for that install
  (BepInEx\config\dev.meshghost.tevi.cfg, [Network] BridgePort), so two
  TEVI installs can be given different ones.

  Pseudoregalia: nothing to do either. Its mod walks 127.0.0.1:7778-7785
  the same way, taking the first port a core will have it on and starting
  its own client there.

Something not working? Both meshghost.exe and meshghost-server.exe also
write everything they print to a log file (meshghost.log /
meshghost-server.log) -- if a window closes before you can read what it
said, or there was never a window at all, read the log instead. It's
written next to whichever copy ran: this folder for one you started
yourself, or the mod's own folder for one a game started for you. Each run
adds to the file rather than replacing it, so a crash from ten minutes ago
is still there; every run begins with a "=== meshghost run start ===" line
saying which executable it was, which folder it read its config from, and
whether a game started it or you did.

If a game started MeshGhost for you and you want to SEE it working, set
"show_console": true in that mod folder's config.json -- you'll get a real
window with live output. It's off by default on purpose.

Common things to check:
- The server window (host's machine) should show your name joining.
- "connect_to" in config.json must exactly match the host's real address --
  typos are the usual cause of "nothing happens."
- If playing over the internet (not the same network), the HOST needs their
  port forwarded -- that's their setup, not yours.
- Loaded your game's mod/script and nothing happened? Double-check you
  loaded it from the right folder under games\. For TEVI and
  Pseudoregalia, check you did the one-time copy of meshghost.exe into
  that game's mod folder -- their log names the exact folder it looked in.
- Pseudoregalia, and nothing happens at all? Check meshghost.log in the
  MeshGhostPseudo folder. No log file means the mod never started the
  client: look in ue4ss\UE4SS.log, which will say whether meshghost.exe was
  missing (antivirus is a real possibility -- see the note below) or the
  start itself failed. Also make sure the MESHGHOST_NO_AUTOSTART switch
  isn't set (see its section above) -- that deliberately tells the mod not to
  start the client, so it is the expected result rather than a fault if
  somebody set it earlier and forgot.
- Edited config.json and nothing changed? Open meshghost.log and find the
  "config loaded from ..." line -- it prints the full path of the file it
  actually read. With a mod that starts MeshGhost for you, that's the copy
  in the MOD's folder, not the one next to this README.

Want to see whether it's actually working, and what it's costing you?
Start the client from a command prompt with -stats and a time, e.g.

    meshghost.exe -stats=10s

and every 10 seconds it writes one summary line (to the window and to
meshghost.log): your round-trip time to the host, how many other players
it knows about versus how many it is actually drawing, and how many bytes
it has sent and received with an hourly rate -- which is the real answer
to "how much data is this using", measured on your own connection rather
than read off the table above. It's off unless you ask for it, and costs
nothing when off.

If you're HOSTING, the server has the matching switch:

    meshghost-server.exe -introspect=30s

which periodically logs what it currently believes -- which rooms exist,
who is in each one and over which transport, and how much position data it
is actually relaying (including how much of it is going to players who are
in a different area of the game and will discard it). That last part is
the host-side answer to the bandwidth tables above, measured rather than
predicted. It also shows anything the server is holding on someone's
behalf, which only applies to features nothing shipped uses today. It
prints nothing secret -- no room codes, no game data.

If your antivirus flags MeshGhost
---------------------------------
It may, and it is a false positive. meshghost.exe and meshghost-server.exe
are unsigned programs written in Go, and two separate things react to that:
scanners often don't recognise the shape of Go binaries (Go's own FAQ says
this is common and almost always wrong -- go.dev/doc/faq), and Microsoft
Defender may show a name ending in "!ml", which means a machine-learning
guess rather than a match against anything known.

What you can do:

1. Check the file is the one we published. The Releases page shows a
   SHA-256 next to every download -- GitHub computes it, not us. Run
   `Get-FileHash <file> -Algorithm SHA256` in PowerShell on the zip you
   downloaded; if it matches, it is exactly what the build produced, and
   the build is public.

2. If it is specifically the Pseudoregalia mod STARTING meshghost.exe that
   your scanner objects to, set the environment variable
   MESHGHOST_NO_AUTOSTART to anything and start meshghost.exe yourself
   instead. That path is unchanged and fully supported.

3. If a file has already been quarantined or deleted, that is worth knowing:
   the mod's log (ue4ss\UE4SS.log for Pseudoregalia) will say it could not
   find meshghost.exe, which looks identical to never having installed it.

4. Reporting it to your antivirus vendor as a false positive genuinely helps
   -- it is what Go's FAQ asks people to do, and it is the only thing that
   makes scanners stop.

We intend to get the binaries code-signed (via SignPath's free offering for
open-source projects), which should reduce this. It has not been done yet,
and it is unlikely to remove the problem entirely straight away -- a new
certificate has no reputation built up, and reputation is part of what these
detections weigh. The main README on the project page explains this in more
detail if you want the long version.


Playing on Linux or macOS
---------------------------------
This zip is the Windows build, plus every game's mod. Native Linux and macOS
builds of the client and server are SEPARATE downloads on the same release
page (MeshGhost-linux-server-client-<version>.tar.gz and
   MeshGhost-macos-server-client-<version>.tar.gz),
and each has its
own README explaining what it's for.

You may well not need them. Every game MeshGhost supports today is a Windows
game, so on Linux you're already running the game through Proton/Wine -- and
the Windows client in this zip runs there too, inside the same prefix. For
Pseudoregalia that happens by itself: the mod starts meshghost.exe for you.

The native builds are worth grabbing when you want a real Linux or macOS
process rather than a Wine one -- above all for HOSTING, since a server has no
game attached and no reason to go through Wine at all. If you'd rather your
client be native too, start it before launching the game: Pseudoregalia's mod
checks whether one is already running and uses it instead of starting its own.

One thing to know under Proton/Wine: "show_console" does nothing there. Wine
has no usable console window for a game launched this way, so none can appear
whatever you set -- the client says so in meshghost.log if you ask for one, and
that file carries exactly the same output.

Nothing is lost by that. MeshGhost exits with the game under Proton, confirmed
on a real Linux setup 2026-08-16 across six sessions, including when the game
is killed outright rather than quit normally.

The Pokemon adapters are NOT an exception, despite looking like one. Emerald
and Crystal are BizHawk Lua scripts (games\pokemon\emerald\ and
games\pokemon\crystal\ in this zip) and BizHawk itself runs natively on Linux
and macOS -- but the scripts reach the network through a LuaSocket library
shipped here as a WINDOWS dll (lib\x64\socket-windows-5-4.dll), and there is
no Linux or macOS build of it in this package. Everything else about those
scripts is portable; it is only the socket that is not. Running BizHawk itself
through Proton/Wine is the only route with any chance of working today, and
nobody has tried it.


Ghost collision -- can you bump into a friend's ghost?
------------------------------------------------------
Sometimes, and it depends entirely on which game. There is no single
answer because a ghost is built differently in each one.

  Pokemon Emerald and Pokemon Crystal -- yes. A ghost there is a real
    character standing on a real tile, the same as any NPC, so it takes up
    space and you cannot walk through it. Crystal already gets out of your
    way on its own: a ghost that hasn't moved for a few seconds, or that
    you push against for a moment, becomes walk-through.
  Pseudoregalia -- partly. The ghost is physically present, but reports so
    far are that it does not actually block you; what it does do is shove
    things around if you end up inside one.
  TEVI -- no, never. That ghost is a picture and has no physical presence
    at all.

"ghost_collision": "disabled" asks every game to stop doing any of it. The
host sets it for the whole server; each player can also set it just for
themselves. The strictest setting wins, so a player who turns it off keeps
it off, and a player cannot turn it back on in a room where the host
turned it off.

Two honest caveats:

  It is a REQUEST, not a rule the server can enforce. The server has no
  idea what any of these games are or what collision means in them -- it
  publishes the setting and the game mods honor it. Nothing on the server
  can check that a mod did, and an old mod that predates the setting will
  ignore it entirely. If ghosts are still solid after you set this, the
  mod is the thing to update.

  Turning it off is not free in the two Pokemon games. Solidity there
  comes from the ghost being a real engine character, so the only way to
  make it non-solid is to draw it as an overlay instead -- and an overlay
  doesn't get hidden behind buildings the way a real character does.
  Improving that is being worked on.

Transports -- tcp vs udp vs quic
---------------------------------
"transport" in config.json picks HOW meshghost.exe talks to the server.

Whatever you pick, your client ALWAYS makes first contact over tcp, asks
the host what they serve, and only then switches. That is why you never
need to know port numbers, and why picking something your host doesn't
serve leaves you on a working tcp connection instead of failing.

If you're a PLAYER: leave it on "auto" (the default) and stop reading.
auto asks your host what they serve and takes the best of it, which on a
default host means quic -- so your room_code is already encrypted in
transit without you doing anything.

If you're HOSTING: "transport" is what you actually serve, and you can
serve more than one at once. This is the only place the choice really
matters, since players find whatever you turn on by themselves.

  tcp  (always served regardless; half of the "tcp,quic" server default)
    + Works everywhere, no surprises.
    + The only one we can actually inspect when something goes wrong, so
      it's the easiest to get help with.
    - A lost packet holds up the positions queued behind it until it gets
      resent, so a bad connection can look "stuttery then catch up".
    - Not encrypted BY DEFAULT: your room_code travels in the clear
      unless "tls" is on (it is set to "auto" in the config you were
      given, so between two up-to-date copies it already is encrypted).
      Turning it on does not stop tcp being the inspectable one: on
      "auto" a plain tool still connects to the same port.

  udp  (never chosen for you -- you have to ask for it by name)
    + Handles a bad/lossy connection better -- a dropped position is just
      skipped instead of delaying the next one, so ghosts keep moving
      smoothly instead of freezing and then snapping forward.
    + The lightest of the three -- least added data per update.
    - NOT encrypted, and unlike tcp this can never be fixed. Your
      room_code travels in the clear. If that matters, use quic instead.
    - Harder to troubleshoot.
    - On a healthy connection it is NOT faster (see the note below).

  quic  (the other half of the "tcp,quic" server default)
    + Same loss handling as udp, so the same benefit on a bad connection.
    + Encrypted, and very hard to spoof. Encrypted always, with nothing
      to switch on -- tcp can be encrypted too now, but only if "tls" is
      on at both ends.
    + Shares the same port NUMBER as tcp, so hosting stays one number --
      but it rides on UDP, so forward that number on BOTH tcp and udp.
    - Only if you serve plain udp as well do the two collide -- and quic
      KEEPS the shared number. Plain udp is the one that moves, to
      "listen_udp" (default 7780), because quic is served by default and
      plain udp is opt-in.
    - Harder to troubleshoot.

"But isn't udp the fast one?"  Not quite, and this is the most common
misunderstanding: on a connection that isn't dropping packets, all three
arrive at exactly the same speed. Same route, same physics. What udp and
quic avoid is one lost packet holding up the ones behind it -- so the win
is SMOOTHNESS on a bad connection, not lower ping on a good one.

Short version:
  Playing, not hosting?           auto (the default -- just leave it)
  Want your room_code encrypted?  auto already does this on a default host
                                  -- and with "tls": "auto" the tcp first
                                  contact that carries it is encrypted too
  Hosting, just want it to work?  tcp,quic  (the default)
  Hosting, keep it simplest?      tcp
  Hosting for a flaky group?      tcp,udp   (see the udp warning above --
                                  this drops the encrypted default, so
                                  room codes go back to travelling in the
                                  clear; prefer tcp,quic unless you have a
                                  reason not to)

"auto" is the player default: it asks the host and takes the best on offer,
preferring quic, then tcp, and deliberately never picking udp for you --
choosing an unencryptable transport on someone's behalf isn't a decision a
default should make. Leave it alone and you get the best available.

Hosting: "transport" accepts a list, so you can offer several at once.
Players still pick a single one each, and players on DIFFERENT transports
still share a room and see each other normally.

Port forwarding, if you host over the internet: you need a rule per
transport you actually offer, and the protocol matters --
  tcp  -> forward TCP  on 7777
  quic -> forward UDP  on 7777   (the SAME number as tcp, on purpose --
                                  TCP and UDP are separate, so this is one
                                  number and two rules, not two numbers)
  udp  -> forward UDP  on 7777   (it takes that UDP port itself, which is
                                  why serving udp AND quic makes you set
                                  plain udp to "listen_udp", which
                                  defaults to 7780 -- forward UDP there
                                  as well. quic keeps the shared port)
The server prints exactly what to forward when it starts, so you don't have
to work it out from this table -- look for the "to accept players from
outside this machine, forward:" line.
A player set to a transport you haven't forwarded just sees a timeout with
nothing explaining it, so if someone can't connect, check this first.
