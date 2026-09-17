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
