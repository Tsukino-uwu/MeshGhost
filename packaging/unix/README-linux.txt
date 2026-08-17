MeshGhost -- Linux build
=========================

This download is the MeshGhost client and server built for Linux, and nothing
else. There are no game mods in here -- see "Where are the games?" below,
because the answer probably matters to you.

What's in this folder:
- meshghost-linux-amd64         -- the client, for a normal Intel/AMD machine
                                   (this includes the Steam Deck).
- meshghost-linux-arm64         -- the client, for an ARM machine.
- meshghost-server-linux-amd64  -- the server. Only the person HOSTING runs
- meshghost-server-linux-arm64     this; everyone else only needs the client.
- config.json                   -- the only file you should need to edit.
- README.txt                    -- this file. The full manual (setup,
                                   hosting, transports) is in the Windows
                                   download's own README.txt.
- THIRD-PARTY-NOTICES.txt       -- licenses of the libraries these are built
                                   from. Nothing to do unless you redistribute.

They're ready to run as they are:

    ./meshghost-linux-amd64

(If you're unsure which one you need, `uname -m` prints x86_64 for amd64, or
aarch64 for arm64.)

Setting it up is identical to the Windows version: edit "connect_to" in
config.json to your host's address, set "room" to whatever your group agreed,
and "name" to whatever you want your ghost called. The full explanation of
every setting lives in the Windows download's README.txt -- it's the same
config file and the same program, so rather than keep two copies of that text
in sync (and have them drift), this one deliberately doesn't repeat it.


Where are the games?
--------------------
Every game MeshGhost currently supports is a Windows game:

- Pseudoregalia and TEVI use mods that are Windows DLLs. They run under
  Proton/Wine, inside the game's own prefix.
- Pokemon Emerald is a Lua script for BizHawk, which does run natively on
  Linux -- grab it from the Windows download's games\pokemon\emerald\ folder;
  the script and its libraries are not Windows-specific.

So for Pseudoregalia and TEVI, the mod runs inside the Proton prefix and will
start the WINDOWS meshghost.exe from that same prefix -- which is expected to
work, and is why you may not need this download at all.

This build is useful when you specifically want a native binary:
- Hosting. A server has no game attached, so there is no reason to run it
  through Wine.
- You'd rather the client be a real Linux process than a Wine one. Start it
  before launching the game: Pseudoregalia's mod checks whether a client is
  already listening and uses that one instead of starting its own.


Honesty about testing
---------------------
This build is compiled and its test suite runs on Linux on every change, but
no one has yet played with it. If something misbehaves, that's genuinely worth
reporting rather than assuming it's your setup.

If a ghost never appears, meshghost.log (written next to whichever binary ran)
is the first thing to look at -- it records the address it connected to and
which config.json it actually read.
