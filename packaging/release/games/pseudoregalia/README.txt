MeshGhost -- Pseudoregalia setup
=================================

STATUS: FEATURE COMPLETE, but still EXPERIMENTAL. As of 2026-08-27 a ghost does
essentially everything the character it copies does -- position, facing and the full
animation set, the slide and crouch pose, wall riding, the afterimage trail in whatever
colour the move actually produced, outfits, the Dream Breaker (equipped, thrown, and its
landed glow), the healing and charge effects, the ranged shot, and dying and respawning.
A real session with two players on two separate machines was confirmed 2026-08-16.

Still experimental because that is a handful of sessions on one or two pairs of machines,
not broad testing, and because a few known rough edges remain -- most visibly a brief
black flash the moment somebody's ghost appears. If something doesn't work, that's useful
information -- there's nowhere to report it yet, but don't assume it's your setup.

What you need, once:
- Your own legally-obtained copy of Pseudoregalia. That's it -- everything else the mod
  needs is already in this folder.

What's in this folder:
- pseudoregalia\ -- the mod, already in the folder shape your game install expects.
  Drag this whole pseudoregalia folder into your Steam install's Pseudoregalia folder.
  It contains the mod itself plus a UE4SS runtime to load it, and nothing else -- none of
  the stock UE4SS extras (cheat manager, debug console, keybind hooks, actor dumper) are
  included, because this mod does not use them and a ghost overlay has no business adding
  them to your game.

Setup, once:
1. Drag the `pseudoregalia` folder from this folder directly into your Steam install's
   Pseudoregalia folder -- the one Steam created, typically
   `...\Steam\steamapps\common\Pseudoregalia\` (NOT the `pseudoregalia` subfolder already
   inside it -- drop this one ON TOP of that outer folder so the two merge).
2. Windows will ask about merging folders and replacing files -- say yes to all of it.
   Nothing already in your install is deleted, and no other mod is unlisted or disabled.

ALREADY USING OTHER MODS? Read this one paragraph.
   MeshGhost is built to go on TOP of an existing setup, and it deliberately ships no mod
   list of its own: UE4SS finds this mod by scanning folders, so it never needs an entry,
   and shipping our own mods.txt/mods.json would have overwritten yours and silently
   unlisted every Lua or Blueprint mod you already had. Your lists are left untouched and
   you do not need to add MeshGhost to them.

   The one thing step 1 DOES replace, if you already have UE4SS installed for another mod,
   is UE4SS itself -- UE4SS.dll, dwmapi.dll and UE4SS-settings.ini. That is usually fine
   (it is a normal UE4SS build), but it means a different UE4SS version and any settings
   you had tuned in that .ini are overwritten. If you would rather keep your own UE4SS,
   copy just this one folder instead of the whole thing:

       pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo\

   That folder is entirely MeshGhost's own and overlaps nothing. It is all the mod actually
   needs; the rest of what is bundled exists only so someone with no UE4SS at all can
   install in one drag.

Setup, once more -- OPTIONAL, and only for auto open/close:
3. If you want the game to start and stop the client for you, copy meshghost.exe (from the
   folder you unzipped, next to the outer config.json) INTO the MeshGhostPseudo mod folder
   you just installed, so you end up with

       ...\Pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo\meshghost.exe

   sitting in the same folder as config.json and the dlls\ folder.

   You can skip this entirely and just open meshghost.exe yourself before you play -- then
   it can live anywhere you like, AS LONG AS a config.json sits in the same folder as it.
   The client reads the config.json next to itself, so the two travel as a pair; on its own
   it falls back to 127.0.0.1:7777 and never reaches your host. This mod folder is the ONLY
   place the exe has to be for the mod to start it for you. If you do copy it, do it again whenever you update MeshGhost.

Setup, once more -- where your settings live:
4. Open config.json in the MeshGhostPseudo mod folder you just installed
   (`...\Pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo\config.json`)
   and set "connect_to" to your host's address, plus "room" and "name". This is the file
   the meshghost.exe you just copied in reads -- NOT the config.json in the folder you
   unzipped. Once the mod is installed inside your game, that outer one is out of reach.

Setup, every time you play:
1. Launch Pseudoregalia normally.
   - If you copied meshghost.exe into the mod folder: that's the whole thing -- the mod
     starts it for you, with no window to leave open and nothing to run first.
   - If you did not: open meshghost.exe yourself first, from wherever you keep it.
   The mod loads automatically via UE4SS either way, and tells MeshGhost which game it is
   on its own.
2. Walk around. Once a friend joins the same server in the same room, you should see their
   goat as a ghost -- correct position, facing, animations, outfit and effects.

Want to see it working rather than take it on faith? Read meshghost.log, which appears in
the same mod folder. On WINDOWS you can also add "show_console": true to that config.json
for a live window.

On Linux (Proton) and macOS (CrossOver) there is no window to show: Wine has no usable
console for a game launched this way, so "show_console" cannot do anything there, and the
client says so in the log if you set it. meshghost.log carries exactly the same output.

Nothing is lost by that, because the problem a window would have warned you about does not
happen -- MeshGhost exits with the game under Proton, confirmed on a real Linux setup
2026-08-16 across six sessions, including when the game was killed outright rather than
quit normally.

If meshghost.log does not exist at all, the mod never got as far as starting the client --
check ue4ss\UE4SS.log, and see the antivirus note in the main README.txt.

Prefer to run it yourself? Two ways, and the first needs no settings at all:

  - Do not copy meshghost.exe into the MeshGhostPseudo folder (or take it back out). With
    nothing there to start, the mod uses whichever client is already running.
  - Or put "autostart": false in this folder's config.json and leave the exe where it is.
    The mod checks that line before starting a client; with it set to false the mod starts
    nothing and uses whichever client is already running. The main README in the folder you
    unzipped has the details under "Turning autostart off".

Either way, double-click meshghost.exe yourself before launching the game -- and remember
it reads the config.json sitting next to it, so keep the two together.

How far behind is a ghost drawn? ("interp" in config.json)
   A ghost is deliberately drawn a fraction of a second behind where its player really is --
   that buffer is what absorbs the internet between you, and "interp" in config.json is its
   size. Bigger = smoother but more behind; smaller = more immediate but every network
   hiccup shows as a stutter. Pseudoregalia ships at 450ms, which was picked by testing on
   a deliberately bad simulated connection (about 200 ping with wobble, 5% packet loss and
   a one-second Wi-Fi dropout every so often -- think bad Wi-Fi playing across the
   Atlantic): 375ms still stuttered now and then there, 450ms did not.

   If your sessions have better ping than that, you can lower it for a more immediate ghost:

       "interp": "450ms"   default -- smooth even at ~200 ping with loss and Wi-Fi dropouts
       "interp": "300ms"   smooth at up to ~120 ping with a little loss (same continent)
       "interp": "250ms"   smooth at up to ~120 ping on a clean connection

   Values in between behave in between. The rule of thumb from measuring: the worse your
   ping WOBBLES (not how big it is -- how much it varies, plus any packet loss), the more
   interp you need. A steady 200 ping needs less than an unstable 100. If ghosts stutter,
   raise it; if they feel too far behind and your connection is good, lower it until you
   see stutter and step one notch back. Both players set their own -- it only affects what
   YOUR screen shows.

Two important notes specific to Pseudoregalia:
- The mod finds its own local bridge port, walking 127.0.0.1:7778-7785 and taking the
  first one a core will have it on, and the config.json beside it deliberately has no
  "local_game_bridge" setting -- the mod passes that port to MeshGhost itself, so there's
  only one place it can be set rather than two that could disagree. That is also what lets
  two copies on one machine work with nothing to configure (see the main README.txt).
- You should stop seeing a friend's ghost while you're in different areas of the castle --
  if you still see one across areas, that's useful to know -- there's nowhere to report it
  yet, but don't assume it's your setup.
