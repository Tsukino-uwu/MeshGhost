# Autoplay — Pseudoregalia (Steam build): the game's autoplay log

**A dated record, not current fact.** Each entry says what was true while it was written; paths and
numbers are left as they were. Current state lives in `status.md`; what the driver reads and does in
`autoplay/README.md`; the measurements behind it in `adapters/pseudoregalia/MEASURED.md`.

**What this file is.** Pseudoregalia's entries in autoplay's log (phase 13), from 2026-09-23 on: the first 3D game,
driven through a UE4SS Lua driver of its own (`autoplay/drivers/ue4ss/`). Autoplay's plan, its core and the shared
driver files log in [../phase13.md](../phase13.md).

## 2026-09-23 — opened: a UE4SS driver, File 8 as a new game, and the player walked and the camera turned

**The user**: *"autoplay, lets start trying to do it for pseudoregalia. you are free to start the game and other things
you need. keep going until i tell you to stop"*, then *"UE4SS might have some tools we can/could use ?"*.

**The user's rulings.** Saves: **File 8** is autoplay's (the other seven are the user's; the save folder is Steam
Cloud-synced), backed up first as `SaveGames.meshghost-backup-20260923` beside the original, 38 files, every hash
matching. The MeshGhost adapter **stays loaded** beside the driver. File 8 was to be deleted with the game's own
hold-X before starting over (*"might have to delete saveslot8 by holding a key before using it"*). Mid-session: *"also
disable chaser ghosts"* -- `chaser.enabled` set false in the client's `config.json` beside the game; the client
reloaded it live (`meshghost.log`: 0 ghosts of your own past).

**Built** (`autoplay/drivers/ue4ss/`, never shipped; the Go core unchanged):
- `mod/Scripts/main.lua`, the only file copied into the game (`ue4ss\Mods\MeshGhostAutoplay\`, with `enabled.txt` and
  `meshghost-autoplay.txt` naming `repo`, `port`, `game`): it loads the driver from the repo, so an edit is live on the
  next `probe_reloader` restart with nothing copied. No config, nothing loads.
- `driver.lua`, protocol 1 for any UE4SS game: a frame loop on the GAME thread (`LoopInGameThreadAfterFrames(1)`, UE4SS's
  engine-tick hook, cleared with the mod on a restart), the socket polled without blocking, `observe`, `exec` with the
  core's token, `cheat`, `wait`, a module's programs and reflexes, map and mode events. Core on **7874**.
- `games/pseudoregalia.lua`: `observe` (mode `title`/`play`/`paused`/`no_pawn`, map, position, the pawn's `moveState`,
  `actionState`, `controlState`, HP from `BP_HpHitable`, the camera from the camera manager); `press` and `sequence`
  through Enhanced Input injection; `screenshot`; reflexes `walk_to` and `look`.

**The receive wall, found again and got round.** Phase 7.5 had dropped the Lua adapter because ~98% of received lines
arrived corrupt through the vendored LuaSocket. An in-game loopback self-test named the cause: LuaSocket runs on its own
`lua54.dll`, and a string it makes longer than Lua's short-string limit (40 bytes) reads as empty in UE4SS's Lua (43
bytes: length 43, no bytes), while 13 bytes and single bytes read right; sends are fine. UE4SS.dll exports no Lua API
to rebind to (0 of 4,087 exports). So the driver receives in pieces of at most 40 bytes and joins them in UE4SS's own
runtime; a 30,000-byte `exec` answer then made the round trip whole.

**Input, measured** (each in `MEASURED.md`, same date):
- In play, `InjectInputVectorForAction` (on `EnhancedInputSubsystemInterface`, the one local-player subsystem) drives the
  pawn: a 60-frame `MoveUp` moved her ~133 units. MoveUp heads along the camera's yaw (-104.94 and -104.94), MoveRight
  along yaw + 90.
- The camera is a rig: `IA_Look` orbits it around the player and leaves `ControlRotation` alone, so the view is read from
  `PlayerCameraManager`. LookRight raises yaw ~1.4 a frame at full tilt; IA_Look's Y lowers pitch (a positive Y ran it
  to 50, its limit).
- On the title no mapping context is applied (`HasMappingContext` false for both), and the title reads raw keys
  (`UI_TitleScreen_C` has `OnKeyDown`), so injection does nothing there. A `WM_KEYDOWN`/`WM_KEYUP` Space posted to the
  game's window, not focused, turned PRESS START into the main menu -- a key reaches the game without touching the user's
  focus. File Select ignores the arrow keys: its `hoveredFile` stayed empty through Down and Left; it follows the mouse.
- `shot showui` writes the frame with its UI; `HighResShot` leaves the UI out.

**Walked and reached** (run logs under `autoplay/runs/`, 2026-09-23): PRESS START by a posted Space; FILE SELECT by a
posted Space; File 8 deleted by `hoveredFile` set to its slot (the situation a mouse over it makes) and a posted X held
2.6 s (the game's own `deleteHoldTime` is 2.0; `File 8.sav` gone, the other mods' `File 8` files untouched); the screen's
own `onSaveClicked` on that slot wrote a fresh `File 8.sav`, and a posted Space started it: `ZONE_Dungeon`, HP 30 of 30
once the opening shot ended (`controlState` 2 through it, then 0). Then `walk_to` 300 units along +x arrived with y within
a unit, `look` turned the camera to yaw 0 and pitch -28. **Reached**, not walked: the menus took a property write and a
direct call.

**Open:** menu keys come from a PowerShell one-liner (scratch), not the driver; the File Select click and hover are
direct calls. Next: a key helper the driver can drive, snapshots of File 8, what `moveState`/`actionState` mean for
jumps and ledges, and the first room walked.

## 2026-09-23 (same session) — the save slot guarded, snapshots, sight by traces, goto with jumps and backflips

**The save slot was the user's File 5.** Reading the game instance before trying its own save: `activeSaveSlotName` read
"File 5" while running File 8's new game -- a save would have gone over the user's file. File 5 was still identical to
the backup. It was set to File 8, and the driver now holds it there from the first core connection until the game exits
(the save guard, `observe`'s `save`).

**Built** (the driver's Pseudoregalia module; the Go core unchanged): snapshots (the game's `instSaveGameToSlot` copied
out with the position beside it; a restore copies back, calls `reloadAndRespawn` and returns to the spot, to the unit);
`cheat:teleport`; `observe`'s `things` (the actors a player meets, by class, from one `FindAllOf` walk per map or 300
frames, positions by named reads; signs with their own words) and `surroundings` (line traces); `advance_text` (the
mirror and the NPC child read to the end by injected Interact and MenuAdvance); `recent`, the flight recorder;
`reflex goto` (A* over 50-unit floor cells found by traces, each move a sweep of the player's capsule; jumps on rises to
200, backflips to 250) and `reflex reach` (the same search with no target).

**The user's guidance on moving**, while watching: *"you can duck, jump, ledge grab, backflip. even without having
unlocked any items/abilities"*, *"there is also coyotee time when walking of a ledge"*; the backflip is *"going forward,
suddenly stopping, then jumping backwards"*, and *"forward, reverse, jump, then forward again to gain a lot of height"*;
*"normal jumps are still prefered if a backflip is not needed, as they are lower/faster"*; *"the backflip can be useful to
reach certain places"*. Of the measured one: *"yes you did a proper backflip there"*. Of a climb: *"you did an accidental
ledge grab there"*, *"it worked out"*. Recorded in `autoplay/games/pseudoregalia/game.md`.

**Walked** (snapshots `pr_dungeon_start`, `pr_doorway`, `pr_cage_platform`, local): from the first room by its raised
doorway (46 cells, one jump), the corridor, up the hall's 200 ledge with a full jump, along the strip behind the tall wall,
to the raised platform by a hanging cage (1,122 cells, no re-plans). A `goto` onto the top of a small prop 248 up (the
"highest cell" `reach` gave) timed out re-planning in place: re-planning stands still for seconds, and `reach` ranks
props. Both are open.

**Open:** the ledge grab and coyote time unmeasured; the upgrade at (-3350, -4300, 850) near the first room not yet
reached; menus still by a scratch key poster.

## 2026-09-23 (same session) — the user shows the way; the Dream Breaker, three walls and the save crystal walked

**The user steered.** *"you need to find your weapon, then hit some walls, and then you can reach the save crystal"*; the
weapon *"is the only one you can logically reach right with what you have right now"*; of a wall I tried to climb, *"this
is a fence, not something with a ledge you can grab"*; of a corridor, *"this is the wrong direction, you come out here
after getting the sword"*; then *"you need to jump up onto the platforms"*, *"make use of coyotee time if needed. make sure
to ledge grab if you need as well"*, and the offer: *"want me to show a path, then you redoing it afterwards ?"* -- played
*"with some intentional mistakes ... so you have more data to compare against"*.

**Learning from their run.** A long trail (every 3rd frame, ~7 minutes; `game.trail_since`) recorded their play from the
cage platform to the weapon room: 15 hops (takeoff, landing, ledge grab or not), kept in
`autoplay/games/pseudoregalia/routes/dungeon_hops.json` and offered to `goto`'s search as moves beside its own. It showed
the ledge grab as `moveState` 3 (hanging still 6-21 frames, then a climb at ~860 up), and takeoffs in coyote time.

**goto grew** (each fault from a run it failed): leaps across a gap in any direction onto a floor up to 200 higher (a
250-wide jump onto a block), up to 600 across onto a ledge 280 higher caught by a grab; grabs on rises of 200-320
(a second floor probe from a grab's height finds the ledge); run straight at a hop's takeoff at full speed and jump off its
edge in coyote time (threading grid cells slowed her and she slid off); let go of Jump at the top (held into a landing, it
became a second jump); climb from any hang with a Jump press (measured: a grab on a 300 ledge, then Jump, then on top);
a leap's gap test no longer counts the platforms' own edge cells (every leap onto a block had been refused).

**Walked**, `goto` doing the moving: the cage platform to the weapon room (two block jumps, two ledge grabs, the long jump
and the drop); a jump onto the stage took the **Dream Breaker** (the game's upgrade screen; its CONTINUE button answered
neither keys nor injected actions, so the widget's own bound click handler was called: **reached**). A swing reads
`actionState` 2. Then three breakable walls (100 HP each in their own `BP_HpHitable`, ~7 a hit) -- `_5`, `_3`, `_1` --
and the **save crystal**, which saved when struck (not by Interact): `Last Save Point Name` BP_SavePoint_C_2, File 8
changed, Files 1-7 identical by hash. Snapshots (local): `pr_has_weapon`, `pr_wall5_broken`, `pr_wall3_broken`,
`pr_wall1_broken`, `pr_weapon_room`, `pr_upper_1100`.

**Open:** why the planner missed the ledge next to the 500 block from the floor (the grab edge was right; the probe or
sweeps refused it); menus still by the scratch poster and direct calls; combat (the WalkinEgg) untried.

## 2026-09-23 (same session) — the first fight, and goto made robust from its failures

**Walked:** the WalkinEgg fought and **defeated** by `reflex fight` (13 swings, one hit taken, HP 25 of 30; the magic
gauge filled a little, as the upgrade screen said). Then east past the save crystal to the 800 floor at (3446, -2143)
(snapshot `pr_east_800`, local): 1,342 cells, no re-plans, once the fixes below were in.

**The user**, while watching: *"i moved you away a bit"* (to see what goto does); *"its fine to get onto the center of a
platform, instead of just barely at the edge of one. so you actually have time to jump when you get on top of it"*, and
*"you should at least account for getting on top of it + having time to jump while on it afterwards"*.

**goto, each change from a failure seen in the flight recorder:** a 30-frame jump was let go on its first frame (the
let-go-at-the-top rule saw no rising before takeoff) -- now after 8 frames; a re-plan mid-air took the jump's height as
the start -- re-plans wait for the ground; a step counted as reached mid-climb sent her over the ledge she had just caught
-- steps count only when standing; moved 300 off the route (the user), it plans again; a leap from a standstill fell
short -- leaps back up 30 frames, run at the landing and jump off the edge in coyote time, and a leap is only begun from
its takeoff's height; long leaps cost double past 250, so the short straight one wins; landings next to drops cost more
(the user's rule: room to stand and jump again). The file-trigger reloader stalled once; the driver restarts itself
through `exec` (`RestartMod`).
