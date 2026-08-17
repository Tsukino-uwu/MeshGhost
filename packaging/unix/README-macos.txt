MeshGhost -- macOS build
=========================

This download is the MeshGhost client and server built for macOS, and nothing
else. There are no game mods in here -- see "Where are the games?" below,
because on macOS that answer matters a lot.

What's in this folder:
- meshghost-macos-arm64         -- the client, for Apple Silicon (M1 and later).
- meshghost-macos-amd64         -- the client, for an older Intel Mac.
- meshghost-server-macos-arm64  -- the server. Only the person HOSTING runs
- meshghost-server-macos-amd64     this; everyone else only needs the client.
- config.json                   -- the only file you should need to edit.
- README.txt                    -- this file. The full manual (setup,
                                   hosting, transports) is in the Windows
                                   download's own README.txt.
- THIRD-PARTY-NOTICES.txt       -- licenses of the libraries these are built
                                   from. Nothing to do unless you redistribute.

They're ready to run as they are, with one first-time step macOS insists on
(see below):

    ./meshghost-macos-arm64

Setting it up is identical to the Windows version: edit "connect_to" in
config.json to your host's address, set "room" to whatever your group agreed,
and "name" to whatever you want your ghost called. The full explanation of
every setting lives in the Windows download's README.txt -- it's the same
config file and the same program, so rather than keep two copies of that text
in sync (and have them drift), this one deliberately doesn't repeat it.


The first run is blocked, and that's expected
---------------------------------------------
macOS refuses to run programs that aren't signed by a paid Apple developer
account. MeshGhost isn't signed by anyone, so the first launch is blocked.

To allow it, once per file: find it in Finder, right-click (or Control-click)
it, choose Open, and confirm in the dialog. After that it starts normally,
including from the terminal.

If macOS instead claims the file is "damaged and can't be opened", it isn't --
that's the same block, worded badly. The right-click-then-Open route still
works.


Where are the games?
--------------------
This is the honest part: **MeshGhost has nothing to play on macOS yet.**

Every supported game is a Windows game. Pseudoregalia and TEVI use Windows DLL
mods; Pokemon Emerald uses a Lua script for BizHawk, which does have a macOS
build, so that one is at least plausible -- the script is in the Windows
download's games/pokemon/emerald/ folder and isn't Windows-specific, but
nobody has tried it on a Mac.

So what this build is genuinely for today is HOSTING: running the server for
friends who are playing on Windows. That works without any game on this
machine at all.


Honesty about testing
---------------------
This build is compiled on every change, but its test suite runs on Linux and
Windows -- macOS has no test machine at all, and nobody has run it. It is the
least proven thing MeshGhost ships. If something misbehaves, that's genuinely
worth reporting rather than assuming it's your setup.

If a ghost never appears, meshghost.log (written next to whichever binary ran)
is the first thing to look at -- it records the address it connected to and
which config.json it actually read.
