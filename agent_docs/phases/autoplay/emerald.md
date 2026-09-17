# Autoplay — Emerald (vanilla): the game's autoplay log

**A dated record, not current fact.** Each entry says what was true while it was written; paths and
numbers are left as they were. Current state lives in `status.md`; the instructions an agent follows
while playing today in the `play-game` skill (`.claude/skills/play-game/`); what the driver reads and
does in `autoplay/README.md`; the measurements behind it in `adapters/emulator/pokemon/emerald/MEASURED.md`.

**What this file is.** Emerald's entries in autoplay's log (phase 13), from 2026-09-17 on: what was
measured and built in Emerald's driver module, and what was walked or reached with it. Autoplay's plan,
its core, its tools and the shared driver files (`driver.lua`, `text.lua`, `route.lua`) log in
[../phase13.md](../phase13.md), and so does every Emerald entry written before this file existed; that
file's index lists them. A change to shared Lua made from this chat gets its entry there, with a pointer
line here.

## 2026-09-17 — opened: Emerald's autoplay entries continue here

The user chose one autoplay log per game (`../phase13.md`, "the log split"). Emerald's entries so far —
Phase 1's steps and acceptance, the scenario runner's first scenario, the naming keyboard, the truck's
door and the wall clock (`set_clock`) — stay in `../phase13.md` under "Emerald (vanilla), before its own
log" in its index.

## 2026-09-17 (the Emerald chat) — the new game walked from the set clock to MUDKIP, and the starter bag read as a menu

**Walked** (run log `autoplay/runs/2026-09-17_033152.953259.ndjson`, segment 3, **walked**; segment 2, the first try, closed
**reached** by the restore that started it over after the `goto` replays). From `ng_clock_set`: downstairs (MOM and the TV, 8 boxes), out the door mat, into the
BIRCH house by its door (6 boxes), upstairs, A on the Poké Ball on the floor (MAY's 12 boxes), downstairs and out, north to the
exit where the girl stepped into `goto`'s target and it answered `blocked` (the other column of the exit, her 4 boxes), onto
Route 101 (BIRCH's cries, 3 boxes), below the bag, A: the bag screen. `advance_text` answered `stuck` there after 632
frames, as built. Snapshots on the way (gitignored `autoplay/states/emerald/`): `ng_tv_done`, `ng_met_may`,
`ng_route101_birch`, `ng_route101_facing_bag`, `ng_starter_bag` (MUDKIP under the hand), `ng_got_mudkip` (the lab, BIRCH's
"go see MAY?" question; answered YES after it).

**Measured** (`emerald/MEASURED.md`, "The starter bag, and a stale message on its screen after a restore"), with the decomp as
the map for the routines, the selection word and the species table: Left and Right against captures, A, B and YES.

**Built** (`emerald.lua` only). The bag reads as a `menu` (`kind: starter`, the three species, the selection as `cursor`,
`columns: 3`) in `observe`, in `select`'s reader and in the text machine's `readMenu`, so `advance_text` stops `menu_open`
on it and `select MUDKIP` chooses it. Then `select MUDKIP`, `advance_text` to the question's YES/NO, `select YES`,
`advance_text` to `battle_started`, and `battle strongest` through the rescue battle, BIRCH's words and the lab to the nickname
YES/NO (`menu_open`); `select NO` and `advance_text` to BIRCH's last question. **The shared machine is unchanged** (the hook it
already calls reads the bag too), so Crystal's path is untouched.

**What went wrong on the way:**
- **`select` answered "the menu closed or changed while the cursor was moving"** on its first Left: for the 2 frames a move
  takes the task runs two other routines, and the first reader knew only the input routine. Word 0 already holds the new
  ball in both, so they read as the menu too; then TREECKO, MUDKIP, TORCHIC and MUDKIP again each took one `select`.
- **A stale message after a restore.** Restored at `ng_starter_bag`, `observe` read "In my BAG! There's a POKé BALL!" as a
  finished dialogue: the bag screen's own text is an instant print, and after a restore the driver has no record of it.
  A finished message is now taken up only under the two callback2s it was measured right on (the overworld's and the main
  menu's, where BIRCH's intro runs); the same restore then read no dialogue, and `ng_gender`, `new_game` and `rick_challenge`
  still recovered theirs. Regressions after it: the sight scenario 3 of 3; `acc_before_may`, a turn up and A to MAY,
  `advance_text` read her five boxes to `battle_started` and `battle strongest` played her battle to `ended`, with no nudge.
- `emerald.lua`'s main chunk is at 199 of Lua's 200 locals (the bag is one table).

**Seen, not fixed:** `battle` nudged twice in the rescue battle, once before "Wild ZIGZAGOON appeared!" and once on "Go!
MUDKIP!" -- 180 frames with nothing in the progress signature changing, cause not looked at. Also, MAY's box "I have this dream
of becoming friends{FA}with POKéMON" shows the FA scroll command raw (not measured).

**The user, while it ran:** on the starter, *"Mudkip makes the first gym(stone) a bit easier, but starter choice don't really
matter"*; then that TREECKO is also strong against the first gym, and the gym order as they remember it -- *"stone ( weak
against water/grass) / fighting / electric ( strong against water, but mudkip evolves into water/ground) / fire (strong against
grass) / normal / flying (strong against grass) / psychic / ice"*; and a type chart for Generations II-V on Bulbapedia, *"emerald
is gen3, can use this as a map"*. For a later `battle` policy that weighs types: the game's own type table is what gets read
and measured, with the chart as the map.

**Left as it is:** the Emerald instance on vanilla, port 7870, the driver alone on its target, the game after MAY's battle on
Route 103 (the last regression).

**Next for Emerald:** `exec` and noclip (Phase 1's list; `probes/noclip.lua` exists).

## 2026-09-17 (the Emerald chat) — noclip as a cheat, and a pointer: `exec` and cheats still in effect

**Pointer.** `exec`, the `persisting` list and the driver's per-frame `game.tick` are shared core, logged in
`../phase13.md` ("`exec`, and cheats still in effect in the run log").

**Built** (`emerald.lua`). The `noclip {on}` cheat: `probes/noclip.lua`'s mechanism moved into the module and kept in
effect by `game.tick` -- collision cleared within 6 tiles of the player except the border, other characters put on an
elevation the player is not on -- put back when turned off or the driver unloads, dropped after a map change or a
restore. `game.persisting` names it while on. The module's three step helpers from this session became one table, as
the module is at Lua's local ceiling (198 of 200 after noclip).

**Measured** (`emerald/MEASURED.md`, "Autoplay's noclip: through a collision tile and a character"). Route 0.16: blocked
at (5,1) without it, through it with it; route 0.17: blocked by RICK without it, through his tile with it, across a core
restart; every word and elevation put back when it went off, and the walls drawn again in `local_map`.

**Not measured:** noclip's cost per frame, water (still open for the probe in `emerald/UNVERIFIED.md`), a ledge, a map
change or a snapshot while it is on.

**Left as it is:** the Emerald instance on vanilla, port 7870, the driver alone on its target, noclip off, the game on
route 0.17 after the last `goto` regression.

**Next for Emerald:** Phase 1's list is built. Open from this session: the two nudges in the rescue battle's intro, the
FA scroll command read raw, and a `battle` policy that weighs types (the user's notes above).

## 2026-09-17 (the Emerald chat, end of the session) — where Emerald's autoplay stands, for the next chat

**The user:** *"I want to start a new chat for emerald, can we end this one ?"*

**This session's commits** (straight to master, nothing pushed): `b3113ba0` (the route planner into `route.lua`),
`1e52c234` (the wall clock, `set_clock`), `7eea2855` (the per-game logs), `a18c648b` (the starter bag, the walk to
MUDKIP), `3573ac9d` (`exec`, cheats still in effect, noclip). They change Go in `autoplay/` (server, driver, runlog,
`cmd/autoplay`): once pushed, read `gh run list -L 5`.

**Left as it is:** EmuHawk on vanilla Emerald still running, its loader target
`dev-scripts/bizhawk-dev-loader-autoplay.target` at `none` (no driver, no probe), nothing listening on 7870, noclip off,
the game on route 0.17 (the old save, from the last `goto` regression) with no menu open. The Crystal chat's emulator is
also running.

**Snapshots** (gitignored `autoplay/states/emerald/`), the new game's path newest first: `ng_got_mudkip` (the lab after
MUDKIP, BIRCH's "go see MAY?" question up), `ng_starter_bag`, `ng_route101_facing_bag`, `ng_route101_birch`,
`ng_met_may`, `ng_tv_done`, `ng_clock_set`, then last session's `ng_clock` and earlier. The walk's run log:
`autoplay/runs/2026-09-17_033152.953259.ndjson`.

**Open:** `battle` pressed A twice in the rescue battle's intro (restore `ng_starter_bag`, `select MUDKIP`, YES, and
watch the log); MAY's box shows the FA scroll command raw; a `battle` policy that weighs types (the game's own type table
to measure, the user's Gen III chart as the map); noclip's per-frame cost and water; the plan's Phase 2 (`goto` across
maps, `talk`, the stuck classifier).

## 2026-09-17 (the Emerald chat, new session) — the rescue battle's nudge: a battle controller at work counts as progress

**Reached** (run log `autoplay/runs/2026-09-17_041250.019796.ndjson`, every segment reached by a restore). From `ng_starter_bag`:
`select MUDKIP`, `advance_text`, `select YES`, `advance_text` to `battle_started`, and a new snapshot `ng_rescue_battle` on the
battle's first frame. The first try at it landed 543 frames late: the game runs on between two `mcpcall` invocations, so a
snapshot meant for the frame a call answered on goes in the same invocation.

**Measured** (`emerald/MEASURED.md`, "A battle controller at work: the rescue battle's intro"), with `battle_state_probe.lua`
now also logging gBattleMainFunc and gIntroSlideFlags, and the build's `.sym` as the map for the routine names. `battle`'s one
A in the intro landed while battler 1's controller ran by itself for 218 frames, past the 180 a nudge waits; from the snapshot
with no input the controller finished on the same frame. Every other stretch of a busy controller in the battle ended with no
button down, but the message waiting on its arrow and the two menus.

**Built** (`emerald.lua` only). Emerald's `animationPlaying` hook is also true while a battler's bit in
gBattleControllerExecFlags is set and its routine is not one of those three waits; the shared machine already treats that as
progress for up to 600 frames. The one local it replaced became a table, so the module's count of locals is unchanged. **No shared
Lua changed**, so Crystal's path is untouched; the README's line on what counts as change says it.

**Regressions:** `ng_rescue_battle` to BIRCH's nickname YES/NO (`menu_open`), no nudge, twice (the probe on, then off; 3091
frames each); with the probe off, `rick_battle_start` to `ended` with STRING SHOT three times and both level-up pages twice, no nudge;
`acc_before_may`, Up, A, `advance_text` five boxes to `battle_started` and `battle strongest` to `ended` (a win), no nudge.

**Not reproduced:** last session's second nudge on "Go! MUDKIP!"; the send-out's two routines, now counted, ran 139 frames.

**The user, while it ran:** Serebii's Emerald gym page, *"can use this for some info or as a map, tells you what badge allows
each HM to be used"* -- a map for the policy and Phase 2, each fact measured on the game before it is written as one.

## 2026-09-17 (the Emerald chat, same session) — the game's type chart measured, and `battle`'s policy `effective`

**Pointer.** The server's new policy and `text.lua`'s choice detail are shared core, logged in `../phase13.md` ("`battle`'s
policy `effective`").

**Measured** (`emerald/MEASURED.md`, "What a move's type does to its damage"), with a new read-only probe,
`probes/type_calc_probe.lua` (execute hooks at the entries of Cmd_typecalc and Cmd_adjustnormaldamage), and the decomp as the
map. The ROM's table matched all 289 cells of the Gen II-V chart the user named. Ten trials from the new snapshot
`ng_rescue_move_menu`, with MUDKIP's move and ZIGZAGOON's type bytes written in the battle copy through `exec`: ×1.5 for a move
of the attacker's type, then each table entry for the foe's two types, a single type once, the entries after FE included,
each with the flags and message the game printed.

**Built** (`emerald.lua`). One table, `TYPE_CHART` (the module at 199 of Lua's 200 locals): the table read once from the
ROM, the type names (`moveInfo` takes them from it), `observe`'s `types` per battler, and `effectiveMove` -- power × accuracy ×
the same-type bonus × the chart against the battler at the opponent's position, the first move with PP when none scores
above 0, and each move's `weighed` score and the foe's types (`against`) into the log's choice.

**Checked** (all reached, from made states; run log `autoplay/runs/2026-09-17_041250.019796.ndjson`). From the new snapshot
`ng_rescue_action_menu`, the moves and the foe's types written before FIGHT: ROCK/GROUND, `strongest` EMBER against `effective`
MUD-SLAP; WATER/GRASS, WATER GUN against EMBER; GHOST, TACKLE (×0, until its PP ran out) against MUD-SLAP. The probe showed the
game running each chosen move with the multiplier weighed; `effective` against ROCK/GROUND again with the probe unloaded, the
same. RICK's battle under `effective`: TACKLE every turn, `ended`. No nudge in any of them.

**What went wrong on the way:** moves written while the move menu was already open: the game refused Down onto a slot its
menu had opened empty, and `battle` answered `stuck` 4 times of 6 -- written before FIGHT instead.

**Found at the end:** the Crystal chat made Crystal's `strongest` itself weigh the type table and the same-type bonus the same
day (its log, `crystal.md`). So `strongest` now weighs types on Crystal and not on Emerald, where that is `effective`. That
chat's session end, the same night, settles it: next, Crystal's scoring moves behind `effective` and its `strongest` goes back
to power × accuracy, so both games mean the same by each.

## 2026-09-17 (the Emerald chat, end of the session) — where Emerald's autoplay stands, for the next chat

**The user:** *"lets call it here for today, and continue tomorrow"*.

**This session's commits** (straight to master, nothing pushed): `a513a022` (a battle controller at work counted as progress),
and the type chart with `effective` (this entry's commit). The second changes Go in `autoplay/server`: once pushed, read
`gh run list -L 5`.

**Left as it is:** EmuHawk on vanilla Emerald still running, its loader target `dev-scripts/bizhawk-dev-loader-autoplay.target`
at `none` (no driver, no probe), nothing listening on 7870, the game on route 0.17 (the old save) after RICK's battle under
`effective`, no menu open. The Crystal chat's emulator is also running.
**Later the same night** the user closed both emulators, after both chats had ended. To pick up: launch vanilla Emerald
(asking first) with `MESHGHOST_DEV_LOADER_TARGET=bizhawk-dev-loader-autoplay.target` and `AUTOPLAY_GAME=emerald`, put
`autoplay/drivers/bizhawk/driver.lua` in that target, and `restore` a snapshot; the game's own save is the old one on route 0.17.

**Snapshots** (gitignored `autoplay/states/emerald/`), new this session: `ng_rescue_battle` (the rescue battle's first frame),
`ng_rescue_action_menu` (its first action menu), `ng_rescue_move_menu` (its move menu opening). The new game's path is otherwise
as before, `ng_got_mudkip` newest.

**Open:** MAY's box shows the FA scroll command raw;
noclip's per-frame cost and water; the plan's Phase 2 (`goto` across maps, `talk`, the stuck classifier), with the user's
Serebii gym page as a map for the badges each HM needs; `effective` not yet met on a foe whose types matter without a write
(ROXANNE's gym is the first on this path).

## 2026-09-17 (the Emerald chat, Phase 2) — `goto` across maps, ledges, `talk`, and why a step was refused

**Pointer.** The one-way tiles, `goto` with `map`, `talk` and the server's side are shared core, logged in `../phase13.md`
("Phase 2 in the shared core"). Crystal's policies, aligned first this session, are in `crystal.md`.

**Measured** (`emerald/MEASURED.md`, "Ledges, water, and other maps read from the ROM"), from `session_end_route103` on 0.18
with `exec`, `walk`, `goto` and `probes/step_probe.lua`: gMapGroups (the `.sym`'s address) resolving the live header byte for
byte, a map's ROM layout equal to the live grid on every tile, a ledge's hop frame by frame and its refusal from below,
water refusing a step on foot, the player's facing nibble, and the connection offset's sign walked across 0.18's -60 seam.

**Built** (`emerald.lua`). Ledges (0x3B) handed to the planner as one-way down. `mapExits` and `tileOpenOn` read any map's
size, connections, warps and tiles from the ROM, cached per map; `goto` with a `map` other than this one runs the shared
`travel`. `talk` with `characters`, `facing` and `talkStarted`. `describeTile` names a `cause` for a refused tile
(`STEP.cause`). The module's count of locals is unchanged (the new reads live on `routeHooks` and `STEP`).

**The plan's Phase 2 acceptance:**
- **`goto` crosses 3 maps with no model involved** (walked; run log `autoplay/runs/2026-09-17_115738.529490.ndjson`, segment
  "phase 2 acceptance: goto across maps, one call"): one `goto {map: "2.2", x: 7, y: 5}` from Littleroot 0.9 (10,10) went
  0.9, 0.16, 0.10 and into Oldale's Center 2.2 through its door, 54 tiles, 1097 frames, `done` on the tile. The same way
  back, 2.2 to 0.9, 38 tiles, `done`.
- **A staged test classifies a wall, an NPC, an open text box, a ledge and a missing ability**:
  `autoplay/games/emerald/scenarios/stuck_classifier.json`, cheats only, 3 of 3 with no model (`solid`, `one_way_edge`,
  `missing_ability` `surf`, `npc_in_way` on a beaten RICK, `dialogue_open` after A on him), and a copy with the ledge's cause
  expected `solid` failed at that step, naming both.

**Also checked, live:** `goto` (6,4) to (6,7) over the ledge and back round it; 0.18 to 0.10 then 0.10 to 0.9; `talk` with
no `local_id` in Littleroot to a wandering character that had moved a tile, both boxes logged, `closed`; 0.18 (76,9) to
0.25 (2,69) across the -60 seam (reached: a warp beside it first).

**Seen on the way:** two story scripts stopped `goto` `dialogue_open`, as built -- MAY's "Let's hurry home!" on 0.10's south
row and Route 102's "Please don't come in here." on 0.10's west side; a trip from below 0.18's ledges set the east edge
aside (water between, not looked at further) and went round by 0.10 into that second script. Wild encounters in grass
answered `left_overworld` twice (`battle run` after each).

**Not built or measured:** ledges 0x38, 0x39, 0x3A; a cut tree, boulder or other field-move obstacle as `missing_ability`;
`goto` across maps while surfing or on a bike; a dynamic warp; `talk` to a trainer before its battle; the edge chooser
across a side where the nearest open pair is not reachable by a straight hold.

**Left as it is:** EmuHawk on vanilla Emerald (port 7870) running, its loader target with the driver alone, the game on
0.25 at (2,69), no menu open, MUDKIP not healed after the wild battles run from. RICK's defeat flag set by the scenario (memory only).
Crystal closed after its check.

## 2026-09-17 (the Emerald chat, the story) — Littleroot to Petalburg's gym through the tools: POKéDEX, a whiteout, WALLY

**The user, while it ran:** on the warp beside 0.18's east seam, *"this area is not somewhere you will be until you are done
with 2 gyms / you normally never have surf available at this point, or the badge to use it"*; and in Petalburg's gym, *"you
need 4 gym badges, before you can challenge this 5th gym"*. So the story's path is followed from here, and warps only make a
test situation, labelled reached.

**Played** (run log `autoplay/runs/2026-09-17_120845.522443.ndjson`; its first segments reached by the earlier warp, later
ones by restores where named). From 0.25: `goto` Oldale's Center crossed to 0.18's strip and back and walked into POKéFAN
ISABEL's sight; `battle effective` chose MUD-SLAP against PLUSLE (ELECTRIC) every turn and lost -- the first Emerald whiteout,
`ended` with `outcome_raw` 2, the player below Oldale's Center. Then `goto` Littleroot and Birch's lab: `advance_text` through
BIRCH's POKéDEX and MAY's POKé BALLS (16 boxes), MOM's RUNNING SHOES on the way out, and a scratch loop (not in the repo:
`goto`, and `battle effective` on `spotted` or a wild battle, `advance_text` on a message) to Petalburg -- a trainer on Route
102 and two wild battles, won with TACKLE. Petalburg's Center: `talk` to the nurse (after the counter fix), `select YES`,
healed. The gym: `talk` to DAD through WALLY's request to the battle; `battle` through WALLY's catch (after the fix) and DAD's
advice to challenge ROXANNE in Rustboro. Snapshots: `story_got_pokedex`, `story_petalburg`, `story_wally_battle`,
`story_after_wally`.

**Measured** (`emerald/MEASURED.md`, "A warp's arrival, a whiteout, a Center's counter, and WALLY's battle").

**Built** (`emerald.lua`, and the shared hooks logged in `../phase13.md`, "the plan across maps floods each map"): `mapTile`
and `mapTileRaw` (any map's tile through its own tilesets) and each warp's `to_warp`; `talkAcross` (behaviour 0x80);
`gameAnswers` (type flag 0x200 outside the overworld).

**Checked after:** `goto` 0.10 to 2.2 (3 tiles) and 2.2 to 0.9 (38) with the flooded plan; `talk` to the nurse from (4,7),
across the counter, to her YES/NO; WALLY's battle from `story_wally_battle` to `ended` in one call; the stuck classifier 1 of 1;
RICK's battle under `effective`, no nudge.

**Seen, not fixed:** bytes after an FC in "Wild RALTS appeared!" and "RALTS was caught!" read raw; `effective` scores a move's
accuracy and type but not the foe's accuracy drops or a paralysis, so it chose MUD-SLAP seven times against a PLUSLE it could
not outlast (a policy that weighs HP, or `run`, is the caller's choice today).

**Next:** Route 104, Petalburg Woods and Rustboro toward ROXANNE (ROCK: MUD-SLAP ×2, and WATER GUN if MUDKIP learns it).

## 2026-09-17 (the Emerald chat, the first badge) — Petalburg to ROXANNE's STONE BADGE, a whiteout on the way

**The user, while it ran:** *"some rotating trainers look towards the player if you are running/on a bike/going fast"*, and
that opening the START menu one tile from them can shift their timing enough to slip by; *"paths to avoid walking into
trainers sight is prefered whenever possible"*, *"its faster to not fight every single trainer"*; after the loss, *"if you
whiteout you can always just run back, you will be a higher level now than when you tried last time"*, and that exploring
before a gym works too, as it is done after anyway; on the learn-a-move question, *"delete growl"*, then that a variety of
strong moves of different types is worth keeping and status, debuff and buff moves are harder to use than damaging ones;
and that gym leaders and the Elite Four heal mid-fight, as the player can through BAG.

**Played** (run log `autoplay/runs/2026-09-17_120845.522443.ndjson`). From the gym in Petalburg, after a `goto` refused its
exit mats (fixed: planning from elevation 0), the Center healed through `talk` and `select`; the scratch trip loop to
Rustboro: SCOTT's "Excuse me!" at Petalburg's west side, LADY CINDY on Route 104, Petalburg Woods with two BUG CATCHERs
and the TEAM AQUA GRUNT's scene and battle (MUDKIP Lv 10 learned WATER GUN on the way), its north exit (fixed: behaviour
0x64 on Up), RICH BOY WINSTON, and through a door into the Pokémon School (11.4). Rustboro's Center (11.5) healed; `talk` to
ROXANNE past YOUNGSTER TOMMY; a whiteout to her NOSEPASS; back through the gym to ROXANNE again (the user's advice), the
move-forget screen (GROWL for BIDE, the user's choice), her badge, the evolution to MARSHTOMP and BIDE for MUD SHOT (the
user's guidance above). MARSHTOMP Lv 16: TACKLE, MUD SHOT, MUD-SLAP, WATER GUN; `badges` [1]; TM39 in the bag; money 3991.
Snapshots: `story_rustboro`, `story_stone_badge`.

**Measured** (`emerald/MEASURED.md`, "Rustboro: a north arrow warp, a floor at elevation 0, a YES/NO that ignores an early A,
ROXANNE, an evolution").

**Built** (`emerald.lua`; the shared changes in `../phase13.md`, "the first badge"): warp 0x64 entered on Up; a player at
elevation 0 plans onto any level; `characters` falls back to templates for a character not loaded.

**Open, from this stretch:**
- **The learn-a-move question and the evolution scene** are not read: `battle`'s nudges pressed into the first, and it
  stopped `stuck` on the second. Reading both, and a policy for which move to forget (the user's: keep strong moves of
  different types, drop status moves first), is next.
- **Items in a battle** (the BAG inside a battle is not measured), for healing mid-fight.
- **Trainers that turn toward a running player**, and the START-menu timing the user described: not measured.
- `advance_text` read the return from the evolution screen as `battle_started`; FC bytes read raw in several boxes.

**Left as it is:** the game in ROXANNE's gym at (5,3) after the badge, snapshot `story_stone_badge`, no menu open.

## 2026-09-17 (the Emerald chat, end of the session) — where Emerald's autoplay stands, for the next chat

**The user:** *"lets write down what we have learned and then continue in a new chat, im still working on TEVI in the other
chat"*.

**This session's commits** (straight to master, nothing pushed): `df7326f7` (Crystal's policies aligned), `30c3df58` (Phase 2:
`goto` across maps, ledges, `talk`, the stuck classifier), `d97e7eeb` (the flooded plan across maps, `talk` across a counter,
a battle the game answers), `3d6ede04` (`select` presses again, routes out of sight preferred, 0x64 warps, elevation-0
floors). They change Go in `autoplay/server`: once pushed, read `gh run list -L 5`.

**What was learned, in short** (the entries above and `emerald/MEASURED.md` hold the detail):
- **Playing the story is the best test.** Every stretch walked found something a staged test had not: a map cut in two by
  water, a floor at elevation 0, a north arrow warp, a counter, a scripted battle, a fresh YES/NO ignoring A, a character
  not loaded, the learn-a-move question and an evolution.
- **A map's exit list is not a route**: plan over what a walk covers from where the map is entered.
- **The user's playing guidance** (dated in the entries above): keep to the story's path -- no area a badge or SURF gates
  yet, warps only to make a test; avoid trainers' sight wherever a route allows, it is faster; after a whiteout just go
  back, higher level; exploring before a gym is fine too; keep strong damaging moves of different types, drop status moves
  first; leaders and the Elite Four heal mid-fight, and so can the player through BAG; rotating trainers turn toward a
  running player, and the START menu one tile away can shift their timing; NORMAN's gym needs four badges.

**Open, in order:**
1. Read the learn-a-move question, its move list and the evolution scene (Emerald), so `battle` stops `needs_choice` on the
   question instead of nudging into it, and add a forget policy by the user's guidance.
2. The BAG inside a battle: read it, and use a POTION through it.
3. Turn the scratch trip loop into a tool (`goto`, `battle` on `spotted` or a wild battle, `advance_text` on a
   message) -- the plan's Phase 3 reflex layer -- once TEVI has `observe`, teleport and events (the order in
   `../phase13.md`).
4. Smaller: FC bytes read raw; `advance_text` answering `battle_started` as the evolution screen closes; ledges 0x38-0x3A;
   field-move obstacles; trainers turning toward a running player.
Then the story on: Route 116 and Rusturf Tunnel as DEVON's scene sends the player, Dewford and the second badge.

**Left as it is:** EmuHawk on vanilla Emerald running, port 7870, its loader target `dev-scripts/bizhawk-dev-loader-autoplay.target`
naming the driver alone, no core running; the game in ROXANNE's gym (11.3) at (5,3) after the badge, no menu open (snapshot
`story_stone_badge`). MARSHTOMP Lv 16 alone in the party. The run log of the story: `autoplay/runs/2026-09-17_120845.522443.ndjson`.
The scratch loop (`trip.py`) lived in this chat's scratch folder and is not in the repo. Snapshots in the gitignored
`autoplay/states/emerald/`, the story's newest first: `story_stone_badge`, `story_rustboro`, `story_after_wally`,
`story_wally_battle`, `story_petalburg`, `story_got_pokedex`, then last session's `ng_*`.

## 2026-09-17 (the Emerald chat, next session) — the learn-a-move question, the move list and the evolution scene read; `forget` `strong_variety`

**Pointer.** The machine's questions outside a battle's screen, `scenePlaying` and the forget policy are shared core, logged in
`../phase13.md` ("questions asked outside a battle's screen").

**Measured** (`emerald/MEASURED.md`, "The learn-a-move question, the move list and the evolution scene"), with
`battle_state_probe.lua` now also logging the summary screen's block and the task list. Made situations: EXP written through
`exec` (MUDKIP to 2534 from `story_rustboro`, a wild WHISMUR on 0.31, snapshot `learn_wild_battle_start`; MARSHTOMP to 5459 from
`story_stone_badge`, a wild ABRA), with the ROM's learnsets and EXP table read first to know where each question comes.

**Built** (`emerald.lua`, one table `LEARN`). `battleQuestion` reads the battle's YES/NO by the script command at its pointer and
gBattleScripting +0x1F, the evolution's by its task's step and where YES leads, and the move list by the summary screen's block,
each with `options` from the party slot's moves and the move to learn; `observe`'s `menu` and `select` take them too.
`scenePlaying` is the evolution task running.

**Checked** (reached: every run began with a restore and an EXP write). From `learn_wild_battle_start`: `battle effective`
stopped `needs_choice` on "Delete a move to make room for BIDE?"; `select NO`, "Stop learning BIDE?" read `stop_learning`;
`select NO`; `battle effective forget strong_variety` to `ended` in one call through GROWL out, the evolution, and BIDE out for MUD
SHOT, no nudge. The ABRA battle: NO to FORESIGHT, YES to stop, "did not learn". RICK's battle, and the stuck classifier.

**What went wrong on the way:** measuring by hand, A on the list's index 3 forgot WATER GUN: BIDE had taken GROWL's slot 1. The
reader names the entries from memory.

**Seen on the way:** after the badge, walking out of Rustboro's gym ran the story's scene -- a TEAM AQUA grunt's "Get out! Out of
the way!" and DEVON's employee asking for the GOODS back -- which stopped `goto` `dialogue_open` twice; `advance_text` closed both.
That run was a made situation (EXP written), so the story restarts from `story_stone_badge`.

## 2026-09-17 (the Emerald chat, next session) — the bag inside a battle, and a POTION used through it

**Pointer.** `battle`'s `stop_hp_below` is shared core, logged in `../phase13.md` ("the bag in a battle").

**Measured** (`emerald/MEASURED.md`, "The bag inside a battle, and a POTION used through it"). Made situation: `story_stone_badge`,
`give_item` POTION ×3, a wild TAILLOW on 0.31 (snapshot `bag_wild_battle_start`).

**Built** (`emerald.lua`). "Use on which POKéMON?" read as a menu (`kind: party`, the party's names and CANCEL, the cursor from
gPartyMenu +9), in `observe`, `select` and the text machine's menu reader; that reader now also takes the bag's list, so `battle`
answers `menu_open` on a bag opened from a battle instead of `stuck`; `ownHp`. The party reader hangs off the `LEARN` table, as the
module is at Lua's local ceiling.

**Checked** (reached, from the snapshot): `battle effective stop_hp_below 0.6` stopped at 26 of 51; `select BAG`; `battle` answered
`menu_open` on the bag; `select POTION`, `wait` 20, `select USE`, `wait` 60, `select MARSHTOMP`: "MARSHTOMP's HP was restored by 20
point(s)."; `battle` to `ended`, 46 of 51, 2 POTIONs left.

**What went wrong on the way:** calls chained with no wait: `select POTION` straight after `select BAG` found no menu (the bag
was still coming up), and `battle` on the bag then answered `stuck` (its menu reader did not take list menus; fixed).

## 2026-09-17 (the Emerald chat, next session) — the story from the STONE BADGE to DEWFORD

**Played** (run log `autoplay/runs/2026-09-17_131645.118278.ndjson`, segments "story: ..."; the first reached by restoring
`story_stone_badge`, the rest walked). Rustboro's Center healed; the TEAM AQUA grunt's scene; Route 116 (a wild ABRA the trip
loop fought before the user's advice to catch one arrived, YOUNGSTER JOHNSON, SCHOOL KID KAREN, whose SHROOMISH paralyzed
MARSHTOMP); Rusturf Tunnel: the grunt beaten, the DEVON GOODS back, MR. BRINEY and PEEKO met. Walking back to the Center the
story took the controls: DEVON's employee to MR. STONE (the LETTER, a POKéNAV, a heal), MATCH CALL added and its tutorial --
the POKéNAV's screens driven by `press` and pictures, MR. STONE called. A catch of ABRA was prepared (`manual`, the nickname
question read from the decomp only) and dropped at the user's word. MAY at Rustboro's south edge: `battle effective` chose
MUD SHOT (×0.5) against her TREECKO three times, ABSORB (×4) fainted MARSHTOMP -- a whiteout; after it her scene did not run
again. Route 104 through Petalburg Woods in one `goto` to MR. BRINEY's cottage (17.0), BRINEY talked to beside PEEKO's path,
the voyage (DAD's call on the way) to DEWFORD (0.11). MARSHTOMP Lv 18, money 2259. Snapshots: `story_devon_goods`,
`story_pokenav`, `story_dewford`.

**Built** (`emerald.lua`). `effective` takes a resisted or no-damage move only when no neutral or super effective move does
damage (the user: *"its bad to use ineffective moves, they deal less damage"*, *"should always use a neutral or super effective
move, whenever possible"*). The post-catch nickname YES/NO is read as `nickname` from the decomp's map, not measured.

**The user, while it ran:** catch an ABRA for TELEPORT back to the last Center until FLY (its HM and badge); a Pokémon at low
HP or with a status is easier to catch, only wild ones can be caught, and one that faints cannot; Poké Balls lying in the
overworld hold items; PEEKO walks and BRINEY is talked to by standing beside the path, facing it, and pressing as he passes;
then *"you can skip the abra, and continue with the story"*.

**Open from this stretch:** `goto` reads a story script taking the controls as `no_response` and sets the exit aside; the
driver not reconnecting after its core closed mid-program; `talk` to a walking character (wait beside its path); items in Poké
Balls on the ground not yet picked up by any tool; shops (to buy POTIONs) not read; the POKéNAV's screens not read.

## 2026-09-17 (the Emerald chat, next session) — DEWFORD's gym: two whiteouts, its trainers, BRAWLY's KNUCKLE BADGE

**Played** (walked; run log `autoplay/runs/2026-09-17_131645.118278.ndjson`, segments "story: Dewford" and after). The Center healed
(3.1, found after a house, 3.0, by trying doors; the gym, 3.3, found by counting each interior's trainer templates through `exec`
-- the user: Centers, Marts and gyms look unique from outside, so a picture of the town says which door). `talk` to BRAWLY
reached him past every trainer; MARSHTOMP Lv 18 lost to him (a whiteout, money 2259 to 1129). Back, as the user advises: the
gym's trainers by `talk` (BATTLE GIRL LAURA, BLACK BELT TAKAO, BLACK BELT CRISTIAN -- FORESIGHT declined by `forget` at Lv 20 --,
SAILOR BRENDEN, BATTLE GIRL JOCELYN). A heal trip then misfired (below) into BRAWLY at 28 of 62 HP, a second whiteout. Healed,
then BRAWLY at full HP: MUD SHOT every turn through BULK UP, two SUPER POTIONs and a SITRUS BERRY, won at 7 HP -- KNUCKLE BADGE,
TM08; MARSHTOMP Lv 21, money 4076. Snapshots: `story_dewford_gym`, `story_dewford_before_brawly`, `story_knuckle_badge`.

**What went wrong on the way:**
- `goto {map: 3.1}` from the gym's floor at (9,8) answered "no way on foot known from 3.3 (9,8) to 3.1"; from the entrance
  (5,26) the same trip was `done`. Not looked at (the gym's floor elevations, or the part-of-map flood from there).
- The scratch heal script went on to `talk` local 1 after that refusal, and local 1 in the gym is BRAWLY. It now talks only once
  the trip ends `done` in the Center.

## 2026-09-17 (the Emerald chat, next session) — Granite Cave: FLASH, STEVEN's LETTER, and the boat to Slateport

**Played** (walked; run log `autoplay/runs/2026-09-17_131645.118278.ndjson`, segments "story: Dewford to Granite Cave" and
"story: Granite Cave to Slateport"). Route 106's only warp is Granite Cave (24.7; its size and warps read from the ROM through
`exec`); the HIKER gave HM05 FLASH. The west warp was not reachable on 24.7's floor, so `goto` by map to STEVEN's room (24.10,
its layout and templates read the same way): one call planned 24.7, 24.8, 24.9 and 24.10 and crossed them with eight wild
battles on the way (ZUBAT's SUPERSONIC confusion, SABLEYE, ARON super effective). STEVEN took the LETTER (TM47 STEEL WING,
registered). Back the same way, ten more wild battles, Dewford's Center, and BRINEY's menu at the dock (PETALBURG / SLATEPORT /
EXIT, read by the menu reader) to Route 109's beach (0.24). MARSHTOMP Lv 23, money 4076, badges [1, 2]. Snapshots:
`story_steven_letter`, `story_slateport`.

**The user, while it ran:** a REPEL keeps wild Pokémon away while the lead is above their levels -- none in the bag, and a Mart's
list is not read yet.

## 2026-09-17 (the Emerald chat, next session) — Slateport: CAPT. STERN, ARCHIE, and Route 110 to MAY

**Played** (walked; run log `autoplay/runs/2026-09-17_131645.118278.ndjson`, segments "story: Granite Cave to Slateport" and
"story: Slateport to Mauville"). Slateport's doors found by trying and by each interior's size, stairs and characters read from
the ROM (9.2 a house with a counter, 9.9 the harbor, 9.11 the Center, 9.0 the shipyard where DOCK sent the player to the museum,
9.7 and 9.8 the museum -- TEAM AQUA's queue outside let the player through). The museum's fee paid through its YES/NO; STERN on
9.8, two TEAM AQUA GRUNTs in a row, ARCHIE's speech, the DEVON GOODS handed over; SCOTT outside. Route 110 in one trip after the
planner change (PROF. BIRCH's scene, POKéFAN KALEB, wild ELECTRIKE and WINGULLs), then MAY at its north end: her GROVYLE's ABSORB
(×4) against TACKLE, the only neutral move -- a whiteout, the second loss to a GRASS type with MARSHTOMP alone. MARSHTOMP Lv 25,
money 3423. Snapshots: `story_stern_goods`.

**Built** (`emerald.lua`). Levels for `goto` (`elevationStep`, `playerElevation`, the grid's `elevationAt`; LEVELS in the file,
the decomp as the map for the rule beyond the mats and floors measured before), water closed by behaviour 0x15 rather than by
elevation 1 alone.

**Open from this stretch:** a party of one loses to GRASS types however `effective` chooses; a second Pokémon (a catch) is next.

## 2026-09-17 (the Emerald chat, next session) — a Mart, POTIONs, a grind, and MAY's GROVYLE five times

**Played** (walked; segments "story: a Mart in Slateport for POTIONs" to "story: MAY on Route 110 at Lv 30"). Slateport's Mart
found at the user's word (9.13 at (13,26), which I had misread from the warp list); three POTIONs bought (`emerald/MEASURED.md`, "A
Mart"). MAY at Route 110's north end (her trigger at (34,56)), five tries, MARSHTOMP alone each time:

| Try | Lv | Tactic | Result |
|---|---|---|---|
| 1-2 | 25 | `effective` (TACKLE, the only neutral move) | fainted by ABSORB (×4), GROVYLE barely hurt |
| 3 | 26 | MUD-SLAP ×4 then TACKLE (the user's tactic, `manual`) | GROVYLE at 8 HP when MARSHTOMP fell |
| 4 | 26 | the same, POTION under 30 HP | three POTIONs spent back to back before the slaps; ABSORB out-healed each |
| 5 | 30 (grown on Route 110's grass) | MUD-SLAP ×3 then TACKLE | a critical ABSORB took 54 HP; fainted before the third slap |

**The user, while it ran:** status and accuracy moves have this use even against a resisting type; heal only when the next hit
would faint, then attack; SUPER POTIONs heal more and cost more; selling at a Mart raises money, with no buying back; Poké Balls
lying on the ground hold items.

**Built** (`emerald.lua`, commit `e755a1e4`). A Mart's quantity box read; the list not taken as the menu under it or under a
message. **Fixed in the records:** `emerald/MEASURED.md` had lost its `## Not measured yet` heading in the bag entry's edit
(`b7e17c5e`); put back.

**Open:** a party of one against GRASS; money ₽3.

## 2026-09-17 (the Emerald chat, next session) — MAY beaten on luck, Mauville, WALLY, WATTSON's switches and the DYNAMO BADGE

**Played** (run log `autoplay/runs/2026-09-17_131645.118278.ndjson`). At the user's word, a snapshot right before MAY's trigger
(`story_before_may_route110`) and tries from it (reached) with MUD-SLAP ×3 then TACKLE: the third got through, GROVYLE missing
twice, MUD SHOT taking her SLUGMA with MARSHTOMP at 3 HP (`story_beat_may_route110`). Then walked: to Mauville at 3 HP (the trip
loop does not heal first -- it survived TRIATHLETE ALYSSA and two wild battles), where `forget strong_variety` gave up MUD-SLAP for
TAKE DOWN at Lv 31. Mauville's buildings named from their templates' graphics (the nurse 58 in 10.5, the clerk 83 in 10.7, trainers
in 10.0). WALLY at the gym door, beaten. The gym's barriers: `talk` to WATTSON answered "no route" whatever the order of the three
switches `goto` reached, because every route to the fourth, (8,9), walked over the middle switch (4,12), which flips the barriers
mid-walk; the user: all four switches, walking round the middle one to the right. `walk` legs round it through (4,11) and (5,11)
reached (8,9), and `talk` then found WATTSON (a trainer on the way). WATTSON: MUD SHOT four times, DYNAMO BADGE, TM34. MARSHTOMP
Lv 32, money 7357, snapshot `story_dynamo_badge`.

**The user, while it ran:** mud-slap until its accuracy cannot drop further, heal only when the next hit would faint, then attack --
easier with potions that heal more than a hit takes; make a state before a hard fight and get past it on luck.

**Open from this stretch:** `goto` walks over step-on event tiles (the gym's switches: coord events in the decomp's map, not in any
reader yet); a trip loop that heals when low; `forget` weighs no move's side effect (MUD-SLAP's accuracy drop won MAY's fight).

## 2026-09-17 (the Emerald chat, end of the session) — where Emerald's autoplay stands, for the next chat

**The user:** *"lets write down what we have learned from this chat. and then continue with emerald in a new one"* (the TEVI chat
still running beside it).

**This session's commits** (straight to master, nothing pushed): `83221507` (the learn-a-move question, the move list, the
evolution scene, `forget strong_variety`), `b7e17c5e` (the bag in a battle, POTIONs, `stop_hp_below`), `df494a9b` (`effective`
avoids resisted moves, `manual`, `talk` keeps trying), `07c54c3f` and `76af9797` (Dewford, Granite Cave, the boat), `358a67cb`
(`goto` carries the player's level), `e755a1e4` and `6da25b97` (a Mart's quantity box; MAY's five tries; MEASURED.md's heading
restored), `13749745` and `4e1faf4f` (Mauville, the DYNAMO BADGE). They change Go in `autoplay/server`: once pushed, read
`gh run list -L 5`.

**What was learned, in short** (the entries above, `emerald/MEASURED.md` and `../phase13.md` hold the detail):
- **Playing the story keeps finding what staged tests miss**: a learn-a-move question and an evolution mid-battle, a Mart's
  list left active under its quantity box, ground at two elevations joined only through tiles of 0, floor switches that flip a
  gym's barriers when a route walks over them, a pacing gull mistaken for the man beside it, a story scene taking the controls
  mid-route.
- **A party of one hits a wall against a type it is weak to.** MAY's GROVYLE beat a lone MARSHTOMP five times; `effective`
  cannot fix a type matchup, and what won was the user's tactic (accuracy drops, a snapshot before the fight, retries on luck).
  A second Pokémon, and potions that out-heal a hit, are the real answers.
- **Find buildings by who is inside, not by trying doors**: a Center's nurse is graphics 58, a Mart's clerk 83, a gym's templates
  are trainers (Mauville, checked against Slateport and Dewford); the user adds that Centers, Marts and gyms look unique from
  outside. Misreading a warp list cost several doors in Slateport.
- **When a plan fails, look at the ground before retrying**: "no way on foot" was elevation (Route 110), and "no route to
  WATTSON" was a switch on the path, both found by printing the map's grid from the ROM, not by more attempts.
- **The user's playing guidance, dated 2026-09-17** (this session): keep strong damaging moves of different types, status moves
  first to go, and NO to a new move is a choice (with its "Stop learning?" follow-up); use neutral or super effective moves
  whenever possible; status and accuracy moves still have uses against a type that resists them; heal only when the next hit
  would faint, then attack, and potions work best when they heal more than a hit takes; SUPER POTIONs heal more and cost more;
  selling at a Mart raises money, with no buying back; REPELs keep weaker wild Pokémon away; Poké Balls lying in the overworld
  hold items -- pick them up; ABRA's TELEPORT returns to the last Center until FLY (skipped this time, at the user's word); a
  Pokémon at low HP or with a status is easier to catch, only wild ones, and never faint it; make a state before a hard fight and
  get past it on luck; to talk to a walking character, stand beside its path, face it and press as it passes.

**Open, in order:**
1. **A second party member**, then a catch through the battle's BAG (`manual`; the nickname question is read from the decomp
   only, not measured): a GRASS-type answer for MARSHTOMP.
2. **`goto` and event tiles**: it walks over step-on events (a gym's switches, the decomp's coord events); read them and avoid
   them unless they are the target. Also: a story scene taking the controls reads as `no_response` and sets an exit aside.
3. **The scratch loops into tools** (the plan's Phase 3 is next in the plan's order): the trip loop (goto, battle on `spotted` or
   a wild battle, text), healing before a trip when HP is low, item balls picked up (graphics 59 in templates), a buy by count.
4. Smaller: `forget` weighs no side effects (it dropped MUD-SLAP, which won MAY's fight); SELL at a Mart; TMs taught; the driver
   did not reconnect after a core closed mid-program; a finished message outside the overworld is not recovered after a reload;
   FC bytes read raw ("Poof!", "Stop learning").
Then the story on: Route 111 and Route 112 toward Mt. Chimney and Lavaridge (the fourth badge).

**Left as it is:** EmuHawk on vanilla Emerald running, its loader target `dev-scripts/bizhawk-dev-loader-autoplay.target` naming
the driver alone (`battle_state_probe.lua` taken off), no core of this chat running (the TEVI chat's core on 7872 is its own). The
game in WATTSON's gym (10.0) at (5,3) after the DYNAMO BADGE, no menu open: MARSHTOMP Lv 32, 67 of 95 HP (TACKLE, MUD SHOT, TAKE
DOWN, WATER GUN), money 7357, badges [1, 2, 3]. Snapshots in the gitignored `autoplay/states/emerald/`, the story's newest first:
`story_dynamo_badge`, `story_mauville_gym`, `story_beat_may_route110`, `story_before_may_route110`, `story_stern_goods`,
`story_slateport`, `story_steven_letter`, `story_knuckle_badge`, `story_dewford_before_brawly`, `story_dewford_gym`,
`story_dewford`, `story_pokenav`, `story_devon_goods`, then last session's; made test states `learn_wild_battle_start` and
`bag_wild_battle_start`. The run log: `autoplay/runs/2026-09-17_131645.118278.ndjson`. The scratch helpers (`trip.py`, `may.py`,
`gym.py`, `mapinfo.py`, a map-grid reader through `exec`) lived in this chat's scratch folder and are not in the repo.

## 2026-09-17 (the Emerald chat, Phase 3, end of the session) — the knowledge store seeded, two skills proved, one fix, where to pick up

**Pointer.** Phase 3's core, the launcher and the first unattended attempt are logged in `../phase13.md` ("Phase 3").

**Built and walked** (run log `autoplay/runs/2026-09-17_171332.417648.ndjson`): `autoplay/games/emerald/` seeded from this
log and MEASURED.md (`game.md`, `route.md`, `goals.json`); `heal` walked twice (segments 4 and 7) and `trip` twice (5 and 6,
Mauville's Center to Slateport's and back). **Fix** (`emerald.lua`): the plan across maps reads the current map from the
live grid -- WATTSON's gym had 20 tiles differing from the ROM's layout (MEASURED.md, "The live grid against the ROM's
layout").

**The user, while the attempt ran:** *"it needs to continue to the left around the desert"* (in `route.md`, dated).

**Left as it is:** EmuHawk on vanilla Emerald running, the loader target naming the driver alone, no core running. The game
on Route 111 (0.26) at (14,61) by the sandstorm, where the stopped session left it: MARSHTOMP Lv 34, 54 of 100 HP, ROCK SMASH
taught in TACKLE's place, money 10549 (not a snapshot; `story_dynamo_badge` starts every attempt).

**To pick up:** review `autoplay/runs/sessions/2026-09-17_172659/knowledge.reviewed-before-revert.diff` against the play
stream beside it (keep only what a tool answered: the ROCK SMASH man, the uncle, the sandstorm, the maps as `observe` named
them); commit what passes; rebuild `autoplay.exe` and `session.exe` into the chat's scratch folder; start the launcher as its
own hidden process (`Start-Process`), never under the Bash tool's 10-minute ceiling; if the driver does not reconnect after
a core stops, set its target to `none` and back.
