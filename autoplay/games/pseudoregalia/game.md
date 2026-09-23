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
- `moveState` 0 on the ground, 1 in the air, 2 crouched; `actionState` 18 is the skid a backflip starts from, 17 the
  crouch hop. `controlState` 1 or 2 while reading or talking.

## Talking and reading

- Walk within range (a sign's `in_range`), `press` Interact 5 frames, then `advance_text` until `closed`.

## Menus (title, file select)

- They read raw keys, not the injected actions: a key posted to the game's window works (Space advanced PRESS START).
  File Select follows the mouse, not the arrow keys; `hoveredFile` on `UI_FileSelect_C` is what the X-hold delete reads.
  Not yet a driver tool.
