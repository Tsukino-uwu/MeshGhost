# Emerald (vanilla): the way through, as it was walked

**Only what a session walked**: each stretch names its run log (gitignored `autoplay/runs/`) and date. Maps are
`group.number`, as `observe`'s `location.map` names them; a tile is (x,y) on that map. A trip is `run_skill trip` with
that map and tile. **Nothing past the last stretch is known here**: a session that walks further adds the stretch, in
the same form, when it ends. Kept under 8 KB: replace a stretch that is walked better, never add a second copy.

## Centers

Every one: the nurse is local 1, `talk` from (7,4) across the counter, YES, `advance_text` (`run_skill heal` with the
Center's map). Oldale 2.2 (door (6,16) on 0.10), Petalburg 8.4, Rustboro 11.5, Dewford 3.1, Slateport 9.11, Mauville
10.5, Fallarbor 5.4 (door (14,7) on 0.13), Lavaridge 4.5 (door (9,6) on 0.12). A whiteout wakes the player below the
door of the last Center entered (MEASURED.md, 2026-09-17).

## Littleroot to the STONE BADGE

Run log `2026-09-17_120845.522443`. Littleroot 0.9, 0.16, Oldale 0.10, 0.18, 0.17, Petalburg 0.0; BIRCH's lab 1.4
(POKéDEX, POKé BALLS after MAY on 0.18). Petalburg gym 8.1 (door (15,8)): `talk` local 1 (DAD). One trip to Rustboro 0.3
(27,34) crossed 0.19 and the Woods 24.11 (exit (14,5) with Up). Gym 11.3: trip (5,17), `talk` local 1 (ROXANNE); MUDKIP
won at Lv 14-16 with WATER GUN; STONE BADGE.

## The STONE BADGE to Slateport

Run log `2026-09-17_131645.118278`. Trip 0.31 (2,9), `goto` (47,8), `talk` local 6: DEVON GOODS back; MR. STONE's scene
runs on the way back to 11.5. 0.19: trips (10,20), (17,50), BRINEY's cottage 17.0 (5,6), `talk` local 1, then from (7,6)
`talk` local 2 beside PEEKO's path: Dewford 0.11. Gym 3.3 (door (8,17)), BRAWLY local 1: MUD SHOT at Lv 21 won. Trip
24.7 (5,10), `talk` local 1: HM05; trip 24.10 (7,7), `talk` local 1 (STEVEN). BRINEY at 0.11 (11,9), `talk` local 2,
`select` SLATEPORT. Slateport 0.1: museum 9.7 (9,7) then 9.8 (6,3), `talk` local 1 (CAPT. STERN).

## Slateport to the DYNAMO BADGE

Run log `2026-09-17_131645.118278`. One trip to Mauville 0.2 (20,10) over 0.25. MAY's trigger (34,56) on 0.25: MUD-SLAP
three times then TACKLE beat GROVYLE from a snapshot. Gym 10.0 (door (8,5)): every planned route to switch (8,9) crosses
(4,12); `walk` legs through (4,11) and (5,11). `talk` local 1 (WATTSON): MUD SHOT at Lv 32, DYNAMO BADGE.

## The DYNAMO BADGE to Fallarbor

Run log `2026-09-17_181542.300302.ndjson`, 2026-09-17, from WATTSON's gym floor; the user, earlier: *"it needs to
continue to the left around the desert"* and *"you need a mach bike to go up the mud slides"*.
- `run_skill heal` 10.5; trip 0.2 (32,15), `walk up` into 10.2, `talk` local 1: HM06, taught as game.md says (TACKLE).
- Trip 10.7 (3,5), `talk` local 1, BUY: 8 SUPER POTIONs (game.md, Money).
- Trip 0.26 (18,102), `press Up`, `press A`, `advance_text`, YES, `advance_text`: (18,101) smashed. Then trip 0.27 (11,37)
  went (9 calls, four trainers) without smashing (19,100). A trip from 0.26 straight to 24.14 stops on the sandstorm.
- `walk up` into 24.14 (26,36) (a trip at once answers "goto needs the overworld": call it again), trip 24.14 (25,4), `walk right` 1, `walk down`: 0.27 (22,10).
- `goto` (31,10) run: spotted; `battle effective` `stop_hp_below` 0.4 beat KINDLER BRYANT and AROMA LADY SHAYLA.
- **0.13 is not reached by walking up 0.27 or 0.26 (mud slopes, collision rows).** 0.27's east edge (39,8) leads to 0.26 (0,28);
  0.26's west edge rows 7-10 lead to 0.28 (header read through `exec`: 0.28 west of 0.26 at offset 0, 0.27 at 20).
  Trip 0.26 (0,9) (COOLTRAINER WILTON at (9,27)), then trip 0.13 (15,16): 11 calls through 0.28, Fallarbor 0.13.
- Fallarbor 0.13: the Center is 5.4, door (14,7); 5.0 at (15,15) is not (`run_skill heal` 5.0 answered no_rule).

## Fallarbor to MT. CHIMNEY

Run log `2026-09-17_181542.300302.ndjson`, 2026-09-17.
- Trip 0.29 (8,64) (four battles), `walk up` into 24.0 (27,18). Local 3 (graphics 59) at (27,5): FULL HEAL.
- Trip 24.0 (16,22), `talk` local 6 (graphics 119): TEAM MAGMA takes the METEORITE, ARCHIE's scene; no battle.
- `run_skill heal` 5.4 from 24.0 (6 calls); trip 0.27 (22,11) (9-11 calls, through 0.28 and 0.26), `walk up` into 24.14
  (26,4). **Cross 24.14 with `goto` (26,35) and `battle run`**: a trip whited out there (game.md, Battles). `walk down`
  twice, `press B` 60: 0.27 (11,37). Trip 0.27 (28,28) went (3 calls), where an earlier trip to (28,29) had stopped at (25,34).
- `walk up` into 19.0, `talk` local 1, YES, `advance_text` (answers stuck during the ride), `press B` 600: 19.1. `goto`
  (6,10), `walk down` twice, `press B` 60: MT. CHIMNEY 24.12 (17,37).
- Trip 24.12 (10,9) (5 calls, two trainer battles); `talk` local 2 (graphics 196, MAXIE, at (13,6)): MIGHTYENA, ZUBAT, CAMERUPT,
  beaten by SWAMPERT Lv 37 with `battle effective` at 108/131 (ended 94).

## MT. CHIMNEY to the HEAT BADGE

Run log `2026-09-17_181542.300302.ndjson`, 2026-09-17.
- Trip 24.12 (20,40), `walk down` twice, `press B` 60: 24.13 (13,5). Trip 24.13 (14,39) (two battles), `walk
  down` twice, `press B` 60: 0.27 (6,46). Trip 0.12 (10,10): Lavaridge. Heal at 4.5; the gym 4.1 door (5,15).
- **The gym**: 4.1 and 4.2. A hole on 4.1 (behaviour 0x68) drops to the same (x,y) on 4.2; a geyser on 4.2 (0x29)
  throws to the same (x,y) on 4.1, the player then standing one tile right (warp ids read through `exec`). Landing on one does nothing; stepping onto one
  warps. Rows of 0x3B, drawn as collision, were crossed walking down. A trip to 4.1 (13,4) answered unreachable.
  FLANNERY is local 1 at (13,9), reached from geyser 4.2 (12,12). After every warp `press B` 120. The path that worked from 4.1 (11,18), off geyser (10,18) (a `goto` (10,18) from the entrance drops through its hole):
  `goto` (8,10), `walk up` | trip 4.2 (1,13), `walk down` | `goto` (0,11), `walk up` | `walk right` 1, `up` 3, `left` 1, `up`
  1 | `goto` (2,4), `walk up` | `walk right` 5, `up` 1 | `goto` (10,5), `walk down` | `walk down` 4 (jumps the ledge to
  (10,11)) | `walk right` 2, `down` 1 | `talk` local 1. Range-1 trainers (KINDLER COLE, COOLTRAINER GERALD, two more)
  fought on the way. Stepping on 4.2 (0,10) from (0,11) throws the player back up; leave it sideways.
- FLANNERY: NUMEL, SLUGMA, CAMERUPT, TORKOAL, all beaten by SWAMPERT Lv 38 with `battle effective` taking no damage;
  MUDDY WATER learned (WATER GUN forgotten); HEAT BADGE, TM50.
