# Emerald (vanilla): the way through, as it was walked

**Only what a session walked**: each stretch says when and how it was walked, never which log (the logs are gitignored and
local; README, The knowledge store). Maps are
`group.number`, as `observe`'s `location.map` names them; a tile is (x,y) on that map. A trip is `run_skill trip` with
that map and tile. **Nothing past the last stretch is known here**: a session that walks further adds the stretch, in
the same form, when it ends. Kept under 8 KB: replace a stretch that is walked better, never add a second copy.

## Centers

Every one: the nurse is local 1, `talk` from (7,4) across the counter, YES, `advance_text` (`run_skill heal` with the
Center's map). Oldale 2.2 (door (6,16) on 0.10), Petalburg 8.4, Rustboro 11.5, Dewford 3.1, Slateport 9.11, Mauville
10.5, Fallarbor 5.4 (door (14,7) on 0.13), Lavaridge 4.5 (door (9,6) on 0.12). A whiteout wakes the player below the
door of the last Center entered (MEASURED.md, 2026-09-17).

## Littleroot to the STONE BADGE

Walked 2026-09-17. Littleroot 0.9, 0.16, Oldale 0.10, 0.18, 0.17, Petalburg 0.0; BIRCH's lab 1.4
(POKéDEX, POKé BALLS after MAY on 0.18). Petalburg gym 8.1 (door (15,8)): `talk` local 1 (DAD). One trip to Rustboro 0.3
(27,34) crossed 0.19 and the Woods 24.11 (exit (14,5) with Up). Gym 11.3: trip (5,17), `talk` local 1 (ROXANNE); MUDKIP
won at Lv 14-16 with WATER GUN; STONE BADGE.

## The STONE BADGE to Slateport

Walked 2026-09-17. Trip 0.31 (2,9), `goto` (47,8), `talk` local 6: DEVON GOODS back; MR. STONE's scene
runs on the way back to 11.5. 0.19: trips (10,20), (17,50), BRINEY's cottage 17.0 (5,6), `talk` local 1, then from (7,6)
`talk` local 2 beside PEEKO's path: Dewford 0.11. Gym 3.3 (door (8,17)), BRAWLY local 1: MUD SHOT at Lv 21 won. Trip
24.7 (5,10), `talk` local 1: HM05; trip 24.10 (7,7), `talk` local 1 (STEVEN). BRINEY at 0.11 (11,9), `talk` local 2,
`select` SLATEPORT. Slateport 0.1: museum 9.7 (9,7) then 9.8 (6,3), `talk` local 1 (CAPT. STERN).

## Slateport to the DYNAMO BADGE

Walked 2026-09-17. One trip to Mauville 0.2 (20,10) over 0.25. MAY's trigger (34,56) on 0.25: MUD-SLAP
three times then TACKLE beat GROVYLE from a snapshot. Gym 10.0 (door (8,5)): every planned route to switch (8,9) crosses
(4,12); `walk` legs through (4,11) and (5,11). `talk` local 1 (WATTSON): MUD SHOT at Lv 32, DYNAMO BADGE.

## The DYNAMO BADGE to Fallarbor

Walked three times 2026-09-17, from WATTSON's gym; the user: *"it needs to continue to the left around the desert"*, *"you need a mach
bike to go up the mud slides"*.
- `run_skill heal` 10.5 (4 calls); trip 0.2 (32,15), `walk up` into 10.2, `press B` 60, `talk` local 1: HM06, taught
  over TACKLE (the HM is index 5 in the TMs & HMs list; game.md, Money).
- Trip 10.7 (3,5), `talk` local 1, BUY: 8 SUPER POTIONs (game.md, Money).
- Trip 0.26 (18,102), `press Up`, `press A`, `advance_text`, YES, `advance_text`: (18,101) smashed (once it answered
  battle_started, a wild GEODUDE: `battle run_wild` read "Got away safely!" but answered `stuck`). (19,100) was not needed.
- Trip 0.27 (11,37) (9 calls, four trainers). `walk up` into 24.14 (26,36), `press B` 60, `goto` (25,4) run with
  `battle run` on each `left_overworld` (3 goto calls), `walk right` 1, `walk down`, `press B` 60: 0.27 (22,10).
- **0.13 is not reached by walking up 0.27 or 0.26 (mud slopes, collision rows).** 0.27's east edge (39,8) leads to 0.26 (0,28);
  0.26's west edge rows 7-10 lead to 0.28 (header read through `exec`: 0.28 west of 0.26 at offset 0, 0.27 at 20).
  From 0.27 (22,10): trip 0.26 (0,9) (7 calls, two trainers), trip 0.13 (15,16) (11 calls through 0.28): Fallarbor 0.13.
- Fallarbor 0.13: the Center is 5.4, door (14,7); 5.0 at (15,15) is not (`run_skill heal` 5.0 answered no_rule).

## Fallarbor to MT. CHIMNEY

Walked twice 2026-09-17, and a third time where noted.
- `run_skill heal` 5.4, trip 0.29 (8,64) (7 calls, three battles), `walk up` into 24.0 (27,18), `press B` 60. Local 3
  (graphics 59) at (27,5): FULL HEAL.
- Trip 24.0 (16,22) (1 call), `talk` local 6 (graphics 119) answers dialogue_open, `advance_text`: TEAM MAGMA takes the
  METEORITE, ARCHIE's scene; no battle. Once the walk to local 6 answered left_overworld (a wild ZUBAT): `battle
  run_wild`, then `talk` local 6 again (the third walk).
- `run_skill heal` 5.4 (6-12 calls); trip 0.27 (22,11) (9-17 calls), `walk up` into 24.14 (26,4), `press B` 60.
  **Cross 24.14 with `goto` (26,35) run and `battle run`**: a trip whited out there (game.md, Battles). `walk down`
  twice, `press B` 60: 0.27 (11,37). Trip 0.27 (28,28) (3 calls).
- `walk up` into 19.0, `talk` local 1, YES, `advance_text` (answers stuck during the ride), `press B` 600: 19.1. `goto`
  (6,10), `walk down` twice, `press B` 60: MT. CHIMNEY 24.12 (17,37).
- Trip 24.12 (10,9) (5 calls, two trainer battles); `talk` local 2 (graphics 196, MAXIE, at (13,6)): MIGHTYENA, ZUBAT, CAMERUPT,
  beaten by SWAMPERT Lv 36-37 with `battle effective` from 66/128 (`stop_hp_below` stopped at 33; WATER GUN
  fainted CAMERUPT in one hit); again from 50/128 with `stop_hp_below` 0.3, one battle SUPER POTION at 38 (game.md,
  Money), the third walk. Two field SUPER POTIONs (game.md, Money) before going down.

## MT. CHIMNEY to the HEAT BADGE

Walked three times 2026-09-17.
- Trip 24.12 (20,40) (1 call), `walk down` twice, `press B` 60: 24.13 (13,5). Trip 24.13 (14,39) (1-2 battles), `walk
  down` twice, `press B` 60: 0.27 (6,46). `run_skill heal` 4.5 (4 calls, into Lavaridge). Then trip 4.1 (11,18) from
  4.5 (1 call) lands on the path's start below.
- **The gym**: 4.1 and 4.2. A hole on 4.1 (behaviour 0x68) drops to the same (x,y) on 4.2; a geyser on 4.2 (0x29)
  throws to the same (x,y) on 4.1, landing one tile right (warp ids via `exec`). Landing on one does nothing; stepping
  onto one warps. Rows of 0x3B, drawn as collision, were crossed walking down. FLANNERY is local 1 at (13,9), reached
  from geyser 4.2 (12,12); a trip to 4.1 (13,4) answered unreachable. After every warp `press B` 120. The path from 4.1 (11,18):
  `goto` (8,10), `walk up` | trip 4.2 (1,13), `walk down` | `goto` (0,11), `walk up` | `walk right` 1, `up` 3, `left` 1, `up`
  1 | `goto` (2,4), `walk up` | `walk right` 5, `up` 1 | `goto` (10,5), `walk down` | `walk down` 4 (jumps the ledge to
  (10,11)) | `walk right` 2, `down` 1 | `talk` local 1. Off geyser 4.2 (1,14) the player lands at 4.1 (2,14), where
  `goto` answered no_response once and `battle effective` then beat KINDLER COLE and COOLTRAINER GERALD. Stepping on 4.2
  (0,10) from (0,11) throws the player back up; leave it sideways.
- FLANNERY: NUMEL, SLUGMA, CAMERUPT, TORKOAL, beaten by SWAMPERT Lv 37-38 with `battle effective` (WATER GUN, MUD SHOT)
  taking no damage, all three runs (the first learned MUDDY WATER, WATER GUN forgotten); HEAT BADGE, TM50.

## The HEAT BADGE to the BALANCE BADGE

Walked 2026-09-23.
- Out of FLANNERY's gym, MAY's scene on 0.12 (`advance_text`): the GO-GOGGLES.
- Trip 0.0 (15,9) from 0.12 (25 calls): Route 112's right-hop ledges, both 0.26 rocks smashed on the way (`clear_obstacle`,
  YES), wild battles and a trainer.
- MACH BIKE: trip 0.2 (35,8), `walk up` into 10.1, `talk` local 1 (RYDEL), YES, `select` MACH, `advance_text`; register it
  (`register_item`); a `goto` with `run` then mounts it. Mauville to Petalburg riding: 9 calls.
- `run_skill heal` 8.4. The gym 8.1 is rooms on one map: at each door (behaviour 0x8D) `press Up`, `press A`, `advance_text`,
  YES, `advance_text`; `talk` the room's unbeaten trainer and `battle effective`. Any door leads up (the user: the path only
  picks the trainers). NORMAN is local 1 in the GYM LEADER'S ROOM.
- NORMAN: SPINDA, VIGOROTH, LINOONE, SLAKING. Go in at full HP (two field SUPER POTIONs): a SWAMPERT at 85/143 fainted to
  SLAKING's COUNTER after MUD SHOT. SLAKING's TRUANT loafed every other turn: MUD SHOT on its loafing turns, a battle SUPER
  POTION on its others (FACADE, 34 a hit), four rounds. BALANCE BADGE, TM42, and HM03 from WALLY's father.

## The BALANCE BADGE to the FEATHER BADGE

Walked 2026-09-23.
- SURF taught to SWAMPERT over MUDDY WATER (the TMs & HMs pocket, SURF by index). Trip 0.33 (17,10) (Mauville's east, 0.2's
  right edge); the river is crossed with `clear_obstacle` and YES. Route 119 (0.34) is walked (long grass refuses the bike).
- The Weather Institute 32.0, door 0.34 (6,32): every grunt on 32.0 and 32.1 is `talk`, `battle effective` (heal between);
  CASTFORM from the scientist (NO to a nickname), put in slot 2 (game.md, Party order).
- Trip 0.4 (10,4), Fortree. Center 12.2. The gym door (22,11) is blocked by an invisible KECLEON at (25,8): trip 0.35
  (8,7), `talk` local 31 (STEVEN) at (13,15), YES, KECLEON fought, the DEVON SCOPE. Back at (25,7), `talk` local 7, YES:
  it fled.
- The gym 12.1's rotating gates (the user walked them; eight bytes at SaveBlock1 +0x139C name each gate's turn, MEASURED.md):
  from the door `goto` (13,22), then walk: left 9, up 1, left 1, up 2, left 1, down 2, right 2, up 3, right 3, up 4, right 2,
  up 2, left 2, down 2, right 1, down 1, left 1, up 1, right 2, up 4, left 2, up 1, left 2, up 1, left 3, up 1, left 1, up 1,
  right 1, down 2, right 3, up 4, left 1, up 2, left 2, down 6, right 4, down 1, left 1, up 5, right 10, up 1: (15,3), below
  WINONA (local 1). Replayed once; two trainers stop it on the way (fight, heal in the field, finish the move).
- WINONA: SWABLU, TROPIUS, PELIPPER, SKARMORY, ALTARIA. TROPIUS's SOLARBEAM (after SUNNY DAY) takes most of SWAMPERT;
  CASTFORM's POWDER SNOW took it to 7 before a HYPER POTION. What won: TAILLOW sent in as a sacrifice, SUPER POTION on
  SWAMPERT from the bench, SWAMPERT back at 93 finished the rest. FEATHER BADGE, TM40.

## The FEATHER BADGE to TEAM AQUA's hideout

Walked 2026-09-23.
- Route 120, 121 to Lilycove 0.5 (Center 13.6, door (24,14)). MAY at the store door (27,7): `talk` local 17, YES; her
  GROVYLE is the one to switch for (`battle` switch "ask"). The store 13.16 (door (27,6)), 2F 13.17: REVIVE, HYPER POTION,
  MAX REPEL (clerk local 4), ULTRA BALL (local 5).
- MT. PYRE: Route 122 0.37 (22,29) into 24.15, up to 24.22's summit (three grunts); the old woman (local 2): the MAGMA EMBLEM.
- FLY to Lavaridge; the cable car (route.md, MT. CHIMNEY) and down Jagged Pass 24.13 to (16,19), `walk up`: TEAM MAGMA's
  hideout 24.86. Three STRENGTH boulders at (5,22), (7,22), (6,23): from (8,22) STRENGTH on (7,22), then down, left, left,
  left, up, left (to (5,22)); the corridor goes up from (5,21). Leaving the map puts them back. MAXIE in 24.91 at (16,21).
- TEAM AQUA's hideout 24.23 is a water door, 0.5 (70,5) surfed up into; its exit is (13,27), then down. Its guards block
  it until the Slateport harbour scene: Slateport 0.1, `talk` through the crowd at the harbour 9.9 door (28,12) (locals 10,
  11, 9 in turn), `talk` ARCHIE (local 7): the submarine is taken. Then back to the hideout.
- Back in the hideout (the guards gone). 24.24 and 24.25 are floors of warp pads that land on the same floor; the planner
  does not take those, so each leg was a pad search over the map's own warp table (a flood of each landing's floor, a pad
  counted when it borders it) and `goto` onto each pad in turn. The four balls on 24.24 at (15..16, 9..10): from (17,10)
  `talk` local 8 (an ELECTRODE: fought), local 7 (NUGGET), local 5 (the MASTER BALL); local 6 is the second ELECTRODE,
  caught with an ULTRA BALL. MATT (local 1) is in 24.25's dock room, entered by the pad at 24.25 (8,8), whose room is
  reached from 24.24's (12,1) stairs, and that block from 24.25's (3,3) stairs, reached by the pad at 24.25 (31,8).


## Mossdeep's gym (TATE & LIZA), walked 2026-09-23

- Gym 14.0, door (6,35) from Mossdeep 0.6 (38,9). Rooms joined by warp pads (behaviour 0x0e) landing on the same map:
  (3,28)→(1,23), (7,18)↔(8,12), (11,3)↔(11,35), (13,32)↔(21,10), (1,33)↔(20,24). `goto` with `map` "14.0" plans over them.
- Coloured floor switches move every character standing on that colour's arrows one tile round its loop (the gym's
  trainers ride them): yellow (2,21) and (3,30), blue (8,10) and (6,7), red (8,6), green (15,34), purple (23,24), (23,21).
  Step off and back on to press again. `exec` with the map's metatiles (0x250 + 8 per colour) and the characters shows
  each loop; its state was worked out by hand from that.
- The way walked: entrance → (3,28) pad; yellow ×3 at (2,21), row 20 right to (8,18), pad (7,18) → (8,12). Blue at (8,10)
  until the right loop's two sit on (9,8),(10,8); for red, cross left when the left loop's two are on (6,8),(6,9)
  ((7,9),(7,8),(7,7)), press blue once at (6,7), down (6,8) to (4,8), up to (4,4), right to (8,4), red ×3 at (8,6) (the right
  loop's two on (12,5),(12,6)); back the same way to (7,7), blue ×3 at (6,7), down to (8,9), blue once at (8,10), right
  along row 9 and up x=11 to the pad (11,3) → (11,35). Its pocket needs green ×2 at (15,34) first (the loop's free tile
  on (12,34)), reached from the entrance's pad (1,33) → (20,24). Then (12,35),(12,34),(13,34) up to the pad (13,32) →
  (21,10), the leaders at (23,7) and (24,7); (21,6) warps back to the entrance.
- Trainers on the way: 5 double and single psychic fights, all won by SWAMPERT's SURF/EARTHQUAKE.
- First try at TATE & LIZA (CLAYDOL, XATU, LUNATONE, SOLROCK, a double battle, lv 41-42) lost: SWAMPERT went in with 2
  SURF PP left, ELECTRODE fell to CLAYDOL's EARTHQUAKE, EARTHQUAKE was chosen twice into LEVITATE, SOLROCK's SUNNY DAY
  then SOLARBEAM. Restore PP at a Center before a leader.
- Second try, same day, full PP: ELECTRODE fell to CLAYDOL's EARTHQUAKE again; CASTFORM sent in used RAIN DANCE and
  SWAMPERT's SURF took all four. The MIND BADGE (DIVE outside battle) and TM04 (CALM MIND). The gym's run from the Center
  (green, yellow, blue, red and blue presses counted live) is a script in the session, not in the repo yet.

## The Space Center to the Seafloor Cavern, walked 2026-09-23

- Space Center 14.9 (Mossdeep 0.6 (64,15)): four MAGMA grunts on 1F (locals 6-9, 9 on the stairs (13,2)); on 2F 14.10
  three more in a row after YES, then MAXIE and TABITHA with STEVEN as partner (YES; choose three and CONFIRM). STEVEN's
  house 14.7 (0.6 (19,10)): HM08 DIVE. SWAMPERT's four were all HMs but EARTHQUAKE ("HM moves can't be forgotten"), so
  DIVE went on a TENTACOOL caught on Route 124 0.39 (Lv7, an ULTRA BALL).
- Route 128 0.43: the deep water (behaviour 0x12) at (38,27), south of the ring island; A, DIVE, YES: 0.53 (38,27); up
  one into 24.26; B at (6,5): "Light is filtering down", YES: the cavern 24.27.
- 24.28 from (5,18): ROCK SMASH (5,10) from (4,10); STRENGTH on (5,11) from (5,12), pushed up; along row 11, (12,11)
  pushed right. Its (6,2) leads to 24.29's right side, a dead end; its (17,13) to 24.32 (4,1).
- 24.32: (11,7) pushed right twice, (12,8) down, ROCK SMASH (13,8); (15,12) leads to 24.31 (4,1), a pocket with a
  ledge down (0x3b) to its left part. There, the ledges at (10,5)/(10,6) and (7,11)/(7,12) hop right (0x38; `goto` takes
  ledges down only): walk right from (9,5), then (13,1) to 24.29's left side at (4,10). 24.31 (10,15) drops to 24.27, and
  leaving a room puts its boulders back (the planner took it once and 24.28 had to be done again).
- 24.29 left: (4,8) pushed up twice, then right from (3,6), (4,5) pushed up three times, (6,1) to 24.33.
- 24.33 is surfed water with currents (0x50 east, 0x51 west, 0x52 north, 0x53 south; a step onto one slides until the
  next tile is not open): from (14,16) down, up, left, then up six to (4,2), found by simulating the slides over the
  room's tiles; (4,1) to 24.30 (4,15). Short presses did not step there; `walk` one tile did.
- 24.30: (4,15) right to (6,15), up the left column to (8,1): 24.35 (5,12). One AQUA grunt on the way.

## ARCHIE to RAYQUAZA and the RAIN BADGE, walked 2026-09-23

- 24.35: eight boulders; STRENGTH (face one, A, YES), then from (5,8): up, left, up, right, up, left, up, down, right, right,
  up, left, up (worked out over the room's tiles; a push is taken only when already facing the boulder, so one press per
  step, checked by position). Not on the bike: a boulder is not pushed from it. 24.36 (17,42): ARCHIE (MIGHTYENA, CROBAT,
  SHARPEDO); STRENGTH and ELECTRODE's SPARK won. Then KYOGRE wakes and the player is put on Route 128.
- The sea by edges: Mossdeep 0.6 west is Route 124 0.39, south 127 0.42, 128 0.43, 129 0.44, then west 130 0.45, 131 0.46.
  Route 126 0.41 (south of 124): deep water (0x12) round Sootopolis; DIVE at (55,19), underwater 0.51's (45,65) to 24.5,
  B and YES surfaces in Sootopolis 0.7. Route 128's right edge leads to Ever Grande 0.8 (its waterfall 0x13 at x15-26).
- Sootopolis: STEVEN (local 7) walks the player to the CAVE OF ORIGIN 24.37; WALLACE is inside 24.42 (not in `nearby`;
  `talk` found him); answer SKY PILLAR. SKY PILLAR: 0.46 (36,6) from the water at (36,9). First visit, stairs by
  highest map: 24.77 (14,4), 24.78 (14,5) (WALLACE), 24.79, 24.80, 24.81 (11,1); on 24.82 the left stairs (3,1) are
  reached only from 24.81's middle stairs (7,1): drop through 24.82's cracked floor (0xD2) at (6,4) on foot. 24.84
  (10,1) to the top 24.85: RAYQUAZA wakes and leaves.
- FLY to Sootopolis then plays the RAYQUAZA scene; MAXIE, ARCHIE, STEVEN and WALLACE stand by the gym. The gym 15.0: three
  cracked-ice rooms (0x26), each tile stepped once, the stairs (0x47) open when a room is done; paths found by search:
  from (8,20) up left up right right up left up; from (8,15) up left left left up up right right down right right down
  right right up up left left left up; from (8,10) up left left up left down left left up up up right down right right
  up right down right down right down right up up right down right down right up up up left left left left left up. JUAN
  (KINGDRA last) fell to SWAMPERT's EARTHQUAKE. Walking back over the ice drops to 15.1; its stairs lead out.
- HM07 WATERFALL was in the bag by then. The second SKY PILLAR visit has more cracks: on 24.82, MACH BIKE with `reflex
  ride` legs down to y10, right to x12, down to y12, left to x3, up to y4, right to x5 -- it coasted onto (7,4) and
  dropped into 24.81's middle. A 2-tile run-up into a crack fell. RAYQUAZA (Lv70) at 24.85 (14,6): `talk`, BAG, the
  MASTER BALL, caught first throw.
