MeshGhost -- Pokemon Emerald player setup
==========================================

What you need, once:
- BizHawk (https://tasvideos.org/BizHawk), any recent version.
- Your own legally-obtained Pokemon Emerald ROM. Not included -- see the main
  project's agent_docs/licensing.md if you're curious why.

What's in this folder:
- meshghost.exe             -- the local client. One of these per player.
- meshghost_emerald.lua     -- the BizHawk Lua script that reads the game and
                                draws everyone's ghosts.
- lib\x64\                  -- required by meshghost_emerald.lua, keep it
                                next to the script, don't move one without
                                the other.
- config.json               -- THE ONLY FILE YOU SHOULD NEED TO EDIT.
- play-emerald.bat          -- run this (after editing config.json), don't
                                edit this one directly.

Setup, every time you play:
1. Open config.json in a text editor (Notepad is fine) and change:
     "relay" -- whoever is hosting the session's IP:port (they'll give you
               this). "127.0.0.1:7777" only works if YOU are also the host,
               on the same machine.
     "room"  -- whatever your group agrees on; everyone must use the SAME
               room name to end up in the same session. This is NOT a
               password -- there is no real authentication yet. Treat the
               relay address itself as the secret: only give it to people
               you trust.
     "name"  -- whatever you want your ghost to show as to others.
   Only edit the text between the quotes -- keep the quotes, colons, and
   commas exactly as they are, or the file won't parse.
2. Double-click play-emerald.bat. Leave the window open -- it should say
   "connected to relay ... in room ...". If it prints a warning about
   config.json instead, you probably broke the JSON syntax in step 1 --
   the warning will say what's wrong.
3. Open BizHawk, load your Emerald ROM.
4. In BizHawk: Tools -> Lua Console -> open meshghost_emerald.lua (browse to
   this folder). It should say "connected to bridge" once it links up with
   step 2's process.
5. Walk around. Once a friend joins the same relay, you'll see their character
   as a ghost -- correct sprite, facing, and walk/run animation, tracking
   their real movement. No shared world state: items, battles, and story
   progress are all still fully independent per player.

Playing with two people on the SAME machine (testing/local): each instance
needs its own bridge port. Copy this whole folder a second time, and in the
second copy's config.json change "bridge" to "127.0.0.1:7779" (must differ
from the first copy's).

Something not working? Common things to check:
- The relay window (host's machine) should show your name joining.
- "relay" in config.json must exactly match the host's real address --
  typos are the usual cause of "nothing happens."
- If playing over the internet (not the same network), the HOST needs their
  port forwarded -- that's their setup, not yours.
