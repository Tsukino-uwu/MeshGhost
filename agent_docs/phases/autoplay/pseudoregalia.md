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

## 2026-09-23 (same session) — a second demo run, and the slide walked with goto

**The user's second run**, from below NPC_6 to the slide upgrade: *"not a perfect path this time either, but the one i
usually take when getting to the slide ability"*; *"i did take a shortcut with the backflip to get up onto a cage vs the
intended path"*, *"and some coyotee time to have enought distance to make a jump afterwards"*; then while I replayed it:
*"didn't use coyotee time to reach the next cage/ledge"*, *"coyotee time allows you to delay the jump a bit & get a longer
distance"*, *"i didn't do it perfectly, just use it as a map but feel free to improve upon it"*, *"you are not turning the
camera around the way i did while playing. not sure if that affects the angle/movement at all ?"* (it does not: the stick
is recomputed from the camera's yaw every frame), and of the backflip hop *"it only did a jump, not the backflip"*, then
*"now it worked"*. They also asked whether the frame-rate drop could be fixed.

**New from the recording:** a climb pole is `moveState` 5 (climbing, up to 650 a second) and 6 at its top, from where they
jumped on; coyote-time jumps came 6-9 frames after leaving the ground. 13 hops, now marked `flip` and `pole`; every hop
carries the user's run-up and approach path; the file keeps their ground trail, which `goto` prefers to walk.

**What each failure taught** (all from the flight recorder against their run): planner nodes need a level (a landing at
1700 merged with the floor at 800 beneath); a flip hop needs the run-up the skid carries on; a straight run-up clipped a
corner they ran around; a seam in the floor was taken for an edge; steering back at a passed takeoff killed the run
speed; **holding Jump through the apex floats her** -- letting go at the apex had her meet the 2349 ledge 9-30 lower
than their grab, and the grab then worked; a late-coyote "improvement" was worse there and was reverted; a recorded
run-up can lie in the air and must stop at the floor's edge; a hang during a run-up needs a climb pushing at the wall;
the pole's top (state 6) needs its own jump. Planning cost: 142 fps idle, ~89 while planning; now a 1.5 ms time budget
per frame and probes and sweeps cached per map (132 on a first plan, 143 on the same plan again).

**Walked:** `pr_before_crawler` → backflip onto the cage → the grabs → the 2349 ledge → wall `_2` broken → the corridor
and the gap → the pole → the slide, and **the SLIDE taken** ("Press Left Trigger/Q Key on the ground to Slide"; Q is
`IA_Crouch`; its screen's CONTINUE through the widget's handler, reached). Snapshots (local): `pr_2000_before_grab`,
`pr_2349_ledge`, `pr_wall2_broken`, `pr_before_pole`, `pr_after_pole`, `pr_has_slide`.

## 2026-09-23 (same session) — the replay check to the slide, the slide used, and the dungeon's reachable edge

**The user:** *"option2 first, and then option3 (this current area is to teach you how to use slide)"*; mid-run *"its
using backflip instead of normal jumps a lot, even for small things that don't require them"*; then, going away, *"keep
going and don't stop, reach slide + proceed beyond that. try to beat the whole game"*.

**Option 2, the replay check** (a scratch script runs goto/fight/advance_text stage by stage from `pr_dungeon_start`):
reached the slide with no help, a stage failing at most once and passing on a retry. What it took, each from the flight
recorder or the long trail: the accidental backflips were Jump pressed during a run-up's turn-around skid (actionState
18) -- every non-flip jump now waits the skid out; a held Jump on landing onto a higher block jumped her again and off its
far side (vz is 0 on the ground, so "hold while vz > -250" held it) -- every hold lets go once landed; a re-plan capped at
2500 cells answered no_route mid-route; plain A* flooded the level on long routes (22691 cells, 2515 frames) -- now
weighted (1.5): 799 cells, 122 frames; goto now ends on an upgrade screen (controlState stays 0 under one).

**Four game crashes, two causes** (UE4SS access violations, crash reports read): the actor registry and `fight` kept
UObjects across frames, and IsValid on a broken wall's freed actor crashed it -- now kept by path and found again by
StaticFindObject; and twice within seconds of a `RestartMod` self-reload -- the driver now re-runs the game module in
place (`reload_game()` through exec). A probe calling into the title widget as it handed over to the main menu crashed it
once more. Relaunching the game: `steam://rungameid/2365810` (I first launched TEVI's id by mistake and closed it; the
user said so).

**Option 3, past the slide:** the slide room's way out is a slide-only passage under a beam the floor probe read as a
150 rise (a second, low probe finds the floor under it; `slide` edges); the axes' shelf is crossed sliding under the
swinging axes (hit 5 at a time walking). `reach` became an even, resumable flood that lists what it reached: the whole
connected dungeon (30684 cells) reaches NPCs, two save crystals, pole `_1` and wall `_0`, and none of the exits, upgrades
or keys. Wall `_0` (200 HP) took no damage from swings or a slide; key `_2` is up a smooth shaft; upgrade `_3` is on an 850
pillar; flip-into-grab edges (to 350) added 6 cells. A leap I added across a "gap" was a wall the Visibility traces do not
see from inside (reverted). **Open:** how the dungeon continues from here -- the cage chain to save crystal `_3` and hit
switch `_2` in the locked door's room (a +253 hop onto a cage top), poles `_2`-`_4`, and wall `_0`. Snapshots (local):
`pr_has_slide2`, `pr_past_slide_gap`, `pr_ledge2550`, `pr_crystal1`, `pr_upper_3525`, `pr_lockroom`.

## 2026-09-23 (same session) — demos redone, the Keeper, out of the dungeon, Castle Sansa to Indignation

**The user's rule for demos, every game:** *"i demo, you see how i do things, you do it yourself"* -- restore to where
the demo began and redo it; never carry on from their end (now in the `play-game` skill). I had continued from the end
of their map demo once; the map was then retaken on her own.

**Their other guidance:** use coyote time off a cage (the jump came too early on the top itself); only 3-5 enemies must
be beaten (the dungeon's mini boss, 2-4 rooms that lock you in a fight, the last boss) -- ignore every other, route
around it and jump past; the locked door opens with the sword; the map is right of the next crystal's room; missing
the gap before the dungeon's exit drops you to the start; "look for the library"; bubbles are in `documentation.md`.

**Walked on her own:** the hanging-cage climb and switch `_2` (their third run); **the Keeper** (640 HP, 15 a hit),
beaten with 20 of 30 HP left by `fight` style `circle` built from their recorded fight (the recorder now watches an
enemy beside her: their hits landed from 108-314, its attacks are 0.1 s dashes at 1000-1700 speed) after face-tanking
lost; key `_1`, the locked door, crystal `_3`, the gap (the leap's run-up is now a distance: two skids had left her at
340); `ZONE_LowerCastle`; the map and **Indignation** after the user's fourth and fifth runs, the pit crossing first try.

**What broke and why:** planner refusals at thin sills (a walk now retries lifted by the step height, or as a jump);
diagonal leaps counted in cells reached 850 (now capped by distance, 600); landings beside enemies on pit platforms
(an enemy cost, leaps too); my jump-past-enemy fired at a pit edge and she fell (now only where the floor continues);
retries after a pit fall walked the same line (goto now ends `fell`); goto reported pit falls as `hit` (a pit costs 5).
Crashes: one more, from reading every property on the Keeper -- read only named properties. A heal "stuck" on after
the user opened the pause menu cleared on their save reload; cause not found.

**Open:** the library exit (`_7`, `libraryWest`) -- the long route across the castle fell in pits twice; `goto` does not
use bubbles or climb poles by itself; the autoplay mod stays installed in the game's `ue4ss\Mods` (its save guard arms
only when a core connects). Snapshots (local): `pr_before_miniboss`, `pr_has_key1`, `pr_door_open`, `pr_castle_arrive`,
`pr_castle_crystal1_map`, `pr_castle_past_pit`, `pr_castle_indignation`.
