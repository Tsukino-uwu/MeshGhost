# Pseudoregalia (Steam build, vanilla): how to play it with autoplay's tools

**Read at the start of every session.** Measured or observed only: each line names where it came from, and anything
known about Pseudoregalia from anywhere else is only where to look. What the driver reads and each tool does:
`autoplay/README.md` (UE4SS). The bytes and timings behind them: `adapters/pseudoregalia/MEASURED.md`. The dated log:
`agent_docs/phases/autoplay/pseudoregalia.md`. **Kept under 8 KB: update facts in place, never append a diary.**

## A session

- The driver is `ue4ss\Mods\MeshGhostAutoplay` in the install, core on **7874**. It loads from the repo: an edit is live
  after a `probe_reloader` restart of `MeshGhostAutoplay`, and the game needs no relaunch.
- **File 8 is autoplay's; Files 1-7 are the user's and never written** (the user, 2026-09-23). The driver's save guard
  holds the game's save slot on File 8 from the first core connection until the game exits: check `observe`'s
  `save.slot` reads `File 8` before a snapshot. The save folder is Steam Cloud-synced.
- Snapshots are the game's own save of File 8 plus the position beside it; a restore reloads through the game's
  `reloadAndRespawn` and returns to the spot (about 2 s). Snapshot before anything risky.
- The MeshGhost adapter stays loaded (the user, 2026-09-23); its chaser pack is **off** (`chaser.enabled` false in the
  client's `config.json` beside the game, the user's request the same day).

## Seeing

- `observe`: `location` (map, x/y/z in world units, 1 unit = 1 cm; the capsule's centre is 67 over the floor), `camera`
  (yaw is the direction the view looks along), `things` (NPCs, signs with their words, save points, upgrades, exits,
  enemies, hazards, nearest first with `bearing`), `surroundings` (walls along 16 bearings, floor height at 150/400/800
  along 8). `screenshot` is the game's own frame with its UI.
- **Look at the ground before a long move.** A floor-height grid by downward traces (`exec`) found the first room's
  doorway step; a trace that starts inside a wall finds nothing, so a "." beside a tall wall is the wall.
- `reflex reach` floods everywhere `goto` can get to and lists rises too tall for a flip. Its "highest cells" can be the
  top of a prop (a cage lid): judge them against a picture.

## Moving (144 frames a second: every frame count is 1/144 s)

- The stick is relative to the camera: MoveUp walks along the camera's yaw. `walk_to` and `goto` do that sum each frame;
  `look` turns the camera.
- **`goto` {x, y}** plans over the level's collision and walks, jumps and flips on its own. It is the default way to
  move. `walk_to` goes in a straight line and snags on props.
- The player's moves, **the user's list (2026-09-23): duck, jump, ledge grab, backflip, all without any upgrade, and
  coyote time for a moment after walking off a ledge.** Measured: a jump rises 85 (3-frame tap) to 206 (held 80); a
  200 ledge was climbed with a full jump. **The backflip** (the user: going forward, suddenly reversing, then jumping;
  forward again during it to gain height while still going forward) peaked 265, rising nearly straight about 40 past
  the takeoff; the user saw it done right. **Normal jumps are preferred when a backflip is not needed: lower and
  faster** (the user); `goto` only flips on rises over 200. Crouch then Jump is a different move: a low backward hop
  (40 high, ~300 long).
- **A ledge grab** is `moveState` 3 (hanging, still); a Jump press climbs (measured on a 300 ledge). `goto` climbs any
  hang, and plans grabs for rises of 200-320 and leaps across gaps onto ledges up to 280 higher.
- `moveState` 0 on the ground, 1 in the air, 2 crouched, 3 hanging on a ledge; `actionState` 18 is the skid a backflip starts from, 17 the
  crouch hop. `controlState` 1 or 2 while reading or talking.

## The route so far (walked 2026-09-23)

- Start room -> its raised doorway -> the corridor -> the hall's 200 ledge -> the strip -> the cage platform.
- **To the Dream Breaker (attack)**: from the cage platform up the 400 and 600 blocks, west along y ~2900 across two gaps
  caught by ledge grabs (800, then 1100), a long jump down to the 900 platform, and off it west into the weapon room
  (-3246, 3144); a jump onto the stage takes the orb. The user played this way once (`routes/dungeon_hops.json`); `goto`
  uses those hops. The upgrade screen's CONTINUE takes no key or injected action: its widget's bound click handler
  (`UI_NewUpgradePrompt_C`) was called.
- **Then, per the user: break walls, reach the save crystal.** Breakable walls (`BP_BreakableWall_C`) have their own
  `BP_HpHitable` (100 HP, about 7 a hit): `_5` (weapon room south), `_3` (under-roof room, east end) and `_1` (on the 500
  block) opened the way; **the save crystal (`BP_SavePoint_C_2`, at 550, -3450) saves when struck**, not by Interact.

- **To the slide** (the user's second run, "the one i usually take", 2026-09-23): from below NPC_6, a backflip onto a
  cage (their shortcut), four ledge grabs up to the 2349 ledge, down and across to the 2000 corridor, breakable wall `_2`
  at (7450, -2350), east along it and over a gap, **a climb pole** at (12237, -1527) (jump onto it, climb, jump from its
  top), east over the axes' corridor and north to the slide at (16650, 2600) on a pedestal. `goto` walks all of it from
  `pr_before_crawler` with the hops and the trail in `routes/dungeon_hops.json`.
- **Hold Jump through the top of a jump**: it floats her there; letting go at the apex drops her at once and she met a
  ledge the user grabbed 9-30 lower. **Coyote time**: the user jumped 6-9 frames after leaving an edge for more
  distance, and lands in the middle of a platform so there is room to jump again (the user's rules, 2026-09-23).

## Talking and reading

- Walk within range (a sign's `in_range`), `press` Interact 5 frames, then `advance_text` until `closed`.

## Menus (title, file select)

- They read raw keys, not the injected actions: a key posted to the game's window works (Space advanced PRESS START).
  File Select follows the mouse, not the arrow keys; `hoveredFile` on `UI_FileSelect_C` is what the X-hold delete reads.
  Not yet a driver tool.
- Back into File 8 after a relaunch (Steam app 2365810; 2230650 is TEVI's): a posted Space passes PRESS START; the main
  menu's FILE SELECT ignored a posted Space and Enter even with focus, and opened by its own bound handler
  (`BndEvt__UI_MainMenu_newgameButton_..._5_...`, passed the button); `onSaveClicked(UI_FileSlot_7)` loads File 8.
  Never call into a widget while the title hands over to the main menu: a probe there crashed the game (2026-09-23).
