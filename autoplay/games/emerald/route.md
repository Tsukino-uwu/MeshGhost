# Emerald (vanilla): the way through, as it was walked

**Only what a session walked**: each stretch names its run log (gitignored `autoplay/runs/`) and date. Maps are
`group.number`, as `observe`'s `location.map` names them; a tile is (x,y) on that map. A trip is `run_skill trip` with
that map and tile. **Nothing past the last stretch is known here**: a session that walks further adds the stretch, in
the same form, when it ends. Kept under 8 KB: replace a stretch that is walked better, never add a second copy.

## Centers

Every one: the nurse is local 1, `talk` from (7,4) across the counter, YES, `advance_text` (`run_skill heal` with the
Center's map). Oldale 2.2 (door (6,16) on 0.10), Petalburg 8.4, Rustboro 11.5, Dewford 3.1, Slateport 9.11, Mauville
10.5. A whiteout wakes the player below the door of the last Center entered (MEASURED.md, 2026-09-17).

## Littleroot to Petalburg

Run log `2026-09-17_120845.522443`. Littleroot 0.9, Route 101 0.16, Oldale 0.10, Route 103 0.18, Route 102 0.17,
Petalburg 0.0; BIRCH's lab 1.4. Back in the lab after MAY's battle on Route 103: BIRCH's POKéDEX and MAY's POKé BALLS
(16 boxes), and MOM's RUNNING SHOES on the way out. Trip to Petalburg (0.0 (20,17)). The gym 8.1: its door (15,8) on 0.0; `talk` local 1 (DAD)
runs WALLY's request and his catching battle, and DAD sends the player to Rustboro's gym. Leaving 8.1: its mats read
elevation 3 while its floor reads 0 (MEASURED.md, 2026-09-17).

## Petalburg to the STONE BADGE

Run log `2026-09-17_120845.522443`. A trip to Rustboro 0.3 (27,34) crossed Route 104 and Petalburg Woods: SCOTT at
Petalburg's west side, LADY CINDY, two BUG CATCHERs, the TEAM AQUA GRUNT's scene and battle; the Woods' north exit
24.11 (14,5)-(15,5) is left with Up (behaviour 0x64) onto Route 104 0.19 (11,29); RICH BOY WINSTON; a door taken by
mistake was the Pokémon School 11.4. The gym 11.3: trip to (5,17), `talk` local 1 (ROXANNE, not loaded from the door;
YOUNGSTER TOMMY in the way, range 2). MUDKIP lost at Lv 12-14 and won at Lv 14-16 with WATER GUN every turn, then
evolved into MARSHTOMP; STONE BADGE, TM39. Leaving the gym runs a TEAM AQUA grunt's scene and DEVON's employee.

## The STONE BADGE to Dewford

Run log `2026-09-17_131645.118278`. Route 116 is 0.31 (wild grass at (6,15)). A trip to 0.31 (2,9), then `goto` (47,8)
with no map and `talk` local 6: Rusturf Tunnel's grunt beaten, the DEVON GOODS back, MR. BRINEY and PEEKO met. Walking back to Rustboro's Center, DEVON's employee takes the player
to MR. STONE (the LETTER, a POKéNAV, a heal) and the POKéNAV's MATCH CALL tutorial runs (screens driven with `press`).
MAY at Rustboro's south edge was lost, a whiteout (`effective` chose MUD SHOT, ×0.5, against her TREECKO, whose ABSORB
fainted MARSHTOMP), and her scene did not run again. Route 104 0.19: trips (10,20), (17,50), then BRINEY's cottage 17.0 (5,6); `talk` local 1, then from (7,6) `talk`
local 2 beside PEEKO's path (the user: stand beside it, face it, press as BRINEY passes): the boat to Dewford 0.11.

## Dewford and the KNUCKLE BADGE

Run log `2026-09-17_131645.118278`. The Center 3.1 (3.0 is a house). The gym 3.3: its door (8,17) on 0.11, its entrance
(5,26) inside; BRAWLY is local 1. Its trainers were talked to as locals 4, 2, 6, 8, 7 and 3. MARSHTOMP lost at Lv 18 and won at Lv 21 at full HP with MUD
SHOT every turn; KNUCKLE BADGE, TM08. A trip from the gym's floor (9,8) to 3.1 answered "no way on foot"; from (5,26) it
went.

## Dewford to Slateport

Run log `2026-09-17_131645.118278`. Trips to 0.21 (48,16) and Granite Cave 24.7 (5,10), Route 106's only warp; a HIKER
gave HM05 FLASH (`talk` local 1). One trip to STEVEN's room 24.10 (7,7) planned 24.7, 24.8, 24.9 and 24.10 (eight wild
battles); `talk` local 1: the LETTER delivered, TM47. Back to 3.1 to heal; BRINEY at the dock, 0.11 (11,9), `talk` local 2, `select` SLATEPORT:
Route 109's beach 0.24.

## Slateport

Run log `2026-09-17_131645.118278`. Slateport 0.1. The Center 9.11; the Mart 9.13, door (13,26) on 0.1; 9.2 a house with
a counter, 9.9 the harbor, 9.0 the shipyard (DOCK sends the player to the museum). The museum 9.7 (9,7), its fee paid
through a YES/NO, then 9.8 (6,3), `talk` local 1 (CAPT. STERN): two TEAM AQUA GRUNTs, ARCHIE, the DEVON GOODS handed over;
SCOTT outside.

## Slateport to the DYNAMO BADGE

Run log `2026-09-17_131645.118278`. Route 110 0.25 in one trip to Mauville 0.2 (20,10): PROF. BIRCH's scene, POKéFAN
KALEB, wild ELECTRIKE and WINGULLs. MAY's trigger is (34,56) on 0.25 (reached from (34,57)): her GROVYLE beat a lone
MARSHTOMP five times at Lv 25-30, and MUD-SLAP three times then TACKLE won on the third try from a snapshot. Mauville's
Center 10.5, Mart 10.7, gym 10.0 (door (8,5) on 0.2; WALLY at the door, `talk` local 6). In 10.0 the four floor
switches (0,15), (4,12), (3,9) and (8,9) open the barriers, and every planned route to (8,9) crosses (4,12): reach it
with `walk` legs through (4,11) and (5,11). Then `talk` local 1 (WATTSON, a trainer on the way): MARSHTOMP Lv 32 with MUD
SHOT four times, DYNAMO BADGE, TM34.

## The DYNAMO BADGE through 24.14

Run logs `2026-09-17_172659.154119.ndjson` and `2026-09-17_174529.077127.ndjson`, 2026-09-17. The user, watching the
first go back and forth: *"it needs to continue to the left around the desert"*.
- **ROCK SMASH**: rocks (graphics 86) at 0.26 (18,101) and (19,100) stop a trip north; local 46 there points to
  Mauville. Trip to 0.2 (32,15), `walk up` into 10.2, `talk` local 1: HM06. Taught as game.md says (TACKLE forgotten).
  Trip to 0.26 (18,102), `press Up`, `press A`, YES, `advance_text`: "MARSHTOMP used ROCK SMASH!"
- Mauville's Mart 10.7: trip (3,5), `talk` local 1, BUY, SUPER POTION (₽700): 8 bought (game.md, Money).
- Trip to 0.27 (11,37): nine calls, four trainers beaten. Not this way: a trip to 0.27 (28,29)
  stops at (25,34) behind two characters of graphics 119; a trip to 0.13 from there goes onto 0.26's sandstorm at (14,61).
- **24.14**: `walk up` from 0.27 (11,37) arrives at (26,36). Trip to 24.14 (25,4) (two battles), `walk
  right` 1 onto the exit (26,4), `walk down` 1: out on 0.27 (22,10). (26,5) is collision: goto answered
  "not an open tile from elevation 3" until the live grid was printed (game.md, Moving).
- **Maps ahead, read from the ROM headers through `exec`**: 0.27 connects to 0.28, 0.12 and 0.26.
  0.28 (100x20): to 0.27, 0.13 and 0.26; warps (33,5) to 30.0, (41,12) and (88,5) to 24.104.
  0.13 (20x20): to 0.29 and 0.28; warps (15,15) 5.0, (8,7) 5.1, (14,7) 5.4, (6,17) 5.6, (1,6) 5.7. 0.12 (20x20)
  connects only to 0.27; warps to 4.0, 4.1, 4.3, 4.4, 4.5. 0.29 (40x80): to 0.30 and 0.13; warps (8,63) 24.0,
  (29,5) 20.0, (27,36) 20.2, (6,46) and (7,4) 24.104. A trip from 0.2 to 0.12 answered "no way on foot"; which map
  holds the fourth gym is not seen yet.
- **The mud slides**: a trip from 0.27 (22,10) to 0.13 (15,16) fought one trainer, read a message, and then kept walking
  up a mud slide until it was stopped. The user, 2026-09-17: *"you need a mach bike to go up the mud slides"*. Nothing
  past 0.27 (22,10) is walked.
