# Autoplay — Crystal (vanilla V1.0): the game's autoplay log

**A dated record, not current fact.** Each entry says what was true while it was written; paths and
numbers are left as they were. Current state lives in `status.md`; the instructions an agent follows
while playing today in the `play-game` skill (`.claude/skills/play-game/`); what the driver reads and
does in `autoplay/README.md`; the measurements behind it in `adapters/emulator/pokemon/crystal/MEASURED.md`.

**What this file is.** Crystal's entries in autoplay's log (phase 13), from 2026-09-17 on: what was
measured and built in Crystal's driver module, and what was walked or reached with it. Autoplay's plan,
its core, its tools and the shared driver files (`driver.lua`, `text.lua`, `route.lua`) log in
[../phase13.md](../phase13.md), and so does every Crystal entry written before this file existed; that
file's index lists them. A change to shared Lua made from this chat gets its entry there, with a pointer
line here.

## 2026-09-17 — opened: Crystal's autoplay entries continue here

Opened by the Emerald chat when the user chose one autoplay log per game (`../phase13.md`, "the log
split"). Crystal's entries so far — steps 1 and 2, the battlers, trainers seen and talked to, the PACK's
pockets and a catch, `set_flag` and the switch question, and `goto` through the shared planner — stay in
`../phase13.md` under "Crystal (vanilla V1.0), before its own log" in its index.

## 2026-09-17 (the Crystal chat) — the party out of a battle, the POKéMON menu, `heal`, and the first Crystal scenario 3 of 3

**Built** (`crystal.lua` only; no shared file changed). `observe`'s `party` carries each Pokémon's moves with PP, held
item, EXP and status byte; the POKéMON menu reads as `party: true` with the party's names, so `select` takes a name; a
`heal` cheat (HP, PP and status); and the first Crystal scenario,
`autoplay/games/crystal/scenarios/trainer_sight_range.json`. Measurements: `crystal/MEASURED.md`, "The party's moves, PP,
item and status, the POKéMON menu, a heal, and a defeat flag cleared in a trainer's line".

**How it was measured.** The battle probe's party lines against the summary's pages (CYNDAQUIL's TACKLE 31/35, LEER 30/30,
BERRY, EXP 158, STATUS OK; BELLSPROUT's VINE WHIP 10/10) and the text probe on the POKéMON menu; `heal` then checked on the
game's own screens (19/ 19, PP 35/35). Every menu was closed again before any code was written.

**The scenario.** It replays Don's sight from `crystal/MEASURED.md` with no model: warp four tiles below him, heal, clear his
defeat flag, 120 frames with nothing, the step to three below `spotted`, then `battle strongest` to `ended` and his flag
set. A run cannot stop at `spotted` on Crystal (a warp written during his script waits for his battle), so every run plays
the battle out, about 1.5 minutes at normal speed. **What went wrong on the way:** the first 3-run pass failed at its first
warp -- its setup had cleared his flag first, with the last run's player standing beside him, and he came at once with no
step. The setup now warps first. Then 3 of 3 passed, each run starting from the last one's end, and two broken copies
failed at the walk with the reason ("trainer.tiles_away: want 4, got 3"; "outcome: want "spotted", got "done"").

**Snapshots:** none new. The instance is left on Route 30 after Don's battle (played out after the last broken run),
the driver alone on its target.

**Next for Crystal:** the key item and TM/HM pockets, badges, movement (the bike; the user: no running in vanilla, a bike,
and running and a faster bike in the Archipelago build), and a `battle` policy that weighs type matchups from the game's
own type table.

## 2026-09-17 (the Crystal chat, same session) — badges: `observe`'s `badges` and a `set_badge` cheat

**Measured on the trainer card** (`crystal/MEASURED.md`, "Badges on the trainer card"): its badge page numbers eight
leaders 1-8; one bit of wJohtoBadges written at a time, the card reopened and each capture compared pixel by pixel with the
no-badge one, bit N-1 drew a badge beside leader N (1, then 1, 4 and 8). `observe` reads `badge_count` and `badges`, and
`set_badge` sets or clears one. The three test badges were cleared again; the save has none, as before. Kanto's byte is not
read.

## 2026-09-17 (the Crystal chat, same session) — the key item pocket and the BICYCLE: `walk` and `goto` ride it

**Built** (`crystal.lua` only). The PACK's key item pocket is read whole like the item and ball pockets, `give_item` takes
key items (once, no quantity), `observe` has `movement` (`on_foot`, `bicycle`), and `walk` and `goto` ride the BICYCLE.
Measurements: `crystal/MEASURED.md`, "The key item pocket, and riding the BICYCLE".

**How it was measured.** The game's own attribute table named which ids are key items; two written into the pocket and the
PACK drew exactly those two and CANCEL, so an entry is one byte. USE on the BICYCLE with the state probe loaded: wPlayerState
1 and a bike graphic, a ride of 40 frames logged step by step (a 6-frame step where walking takes 14, the same begin, end and
stop), and off again the same way. On the bike: `walk` 5 tiles, `walk` into water (`blocked`), `goto` 11 tiles with turns,
and `goto` a door (the player on foot inside).

**Seen, not fixed:** `advance_text` started straight after USE logged the bike's description box once, from the frames the
PACK was closing; it pressed nothing on it.

**Left as it is:** the save holds BICYCLE and OLD ROD (memory only, no in-game save), the player on foot at New Bark (11,14),
every menu closed, the driver alone on its target.

**Next for Crystal:** the TM/HM pocket, surfing (an HM, a badge and a party move, all made with cheats), then a `battle`
policy that weighs type matchups.

## 2026-09-17 (the Crystal chat, same session) — the TM/HM pocket, read whole; a redraw grace too short for it

**Built** (`crystal.lua` only). The TM/HM pocket in `observe`'s bag (`tms_hms`) and read whole as a PACK list (items TM01 /
HM07, each one's move in `moves`), and `give_item` takes TMs and HMs. Measurements: `crystal/MEASURED.md`, "The TM/HM pocket,
and a list that redraws for 11 frames".

**How it was measured.** The attribute table named the 57 TM/HM ids; counts written at three places among them drew exactly
those TMs and the HM in the PACK, and nine drew in order with the moves `TMHMMoves` names. Down through the list with the bag
probe gave the cursor and scroll bytes.

**What went wrong on the way:** `select` up the list from CANCEL failed "the menu closed or changed" 2 times in 13 --
intermittently, and not when the text probe was loaded for the first retries. A temporary log line in the list reader, on the
frames it gave up, showed no ▶ for 11 frames each time the list scrolled, one past the grace the item pocket's 5-frame redraw
had set. The grace is 20 now: 64 of 64 in four batches, two straight after a reload. One batch before those counted 15 of 16
in output not kept; that call is not known. The log line was removed.

**Left as it is:** the save holds TM01-TM08 and HM07 besides the BICYCLE and OLD ROD (memory only), the player on foot at New
Bark (11,14), every menu closed, the driver alone on its target.

**Next for Crystal:** surfing (HM03, the badge that allows it outside a battle, and a Pokémon that knows SURF, made with
cheats, then the game's own SURF from the party menu), then a `battle` policy that weighs type matchups.

## 2026-09-17 (the Crystal chat, same session) — surfing through the game's own SURF; poison walked until it fainted

**Built** (`crystal.lua` only). `movement` `surfing`; `walk` surfs, and `goto` keeps to the water and takes land only as its
target; the party's `status` (`OK`, `PSN`); `set_move` and `set_status` cheats. Measurements: `crystal/MEASURED.md`, "Surfing,
and a poisoned party on foot". To make room, the goto hooks sit in a `do` block and the party offsets in one table: the
module had reached Lua's 200 locals in one chunk.

**How it went.** SURF written onto BELLSPROUT showed in its party menu; the game refused it without a badge ("Sorry! A new
BADGE is required."), and badges 1-4 were tried one at a time: 4 let it through. With it, A facing the water asked "Want to
SURF?". A surf step logged the same as a step on foot, and a step ashore set the state back and walked on. On the pond
`goto` met a wild TENTACOOL; `battle run` got away on its fifth RUN, CYNDAQUIL poisoned.

**The user, while it ran:** a gym page on another site offered as a map for which badge each HM needs -- used as that, and
SURF's badge was measured before it came; *"poison should also do a hurt animation when walking around i think ?"* and *"and
eventually stop when your pokemon gets down to low hp, don't think it can faint a pokemon"*. Both measured rather than
assumed: each poison tick is a ~5-frame hitch between steps that `walk` and `goto` ride through (the flash itself was not
caught in a capture), and the HP went 3, 2, 1, 0 and "CYNDAQUIL fainted!" printed in the overworld. The user: *"ohh guess it
does that in the older games, i know it stops at 1hp for modern pokemon games"*.

**Left as it is:** the save (memory only) holds badge 4, SURF on BELLSPROUT, the key items and TMs from earlier; the party
healed; the player on the BICYCLE in New Bark at (14,10); every menu closed; the driver alone on its target.

**Next for Crystal:** a `battle` policy that weighs type matchups from the game's own table; then the switch question with
the OPTION's battle style set the other way, and the whiteout.

## 2026-09-17 (the Crystal chat, same session) — `battle strongest` weighs the type table and the same-type bonus

**The user, earlier:** *"does "battle strongest" account for move type advantage/disadvantage ? ... physical/special moves, and
pokemon have higher/lower physical/special attack & defense stats"*, and a type chart page offered as a map.

**Built** (`crystal.lua` only). `strongest` scores power × accuracy byte × the game's type table against each of the opponent's
types × 1.5 for a move of the user's type; `observe`'s battlers carry `types`. Measurements: `crystal/MEASURED.md`, "Type
matchups and the same-type bonus".

**How it was measured.** The table read from our identical build; then one TACKLE replayed from `battle_menu` with only its type
byte held -- ELECTRIC, GRASS, GROUND, FIGHTING and FIRE -- and each turn's message and damage read: super effective, not very
effective, no effect, the two multipliers cancelling, and the same-type half again. Live on Route 29 with CYNDAQUIL given
THUNDERSHOCK and EMBER: EMBER against a RATTATA, THUNDERSHOCK against a PIDGEY ("It's super-effective!").

**Not built:** the stats' part (attack against defense, the physical and special split); the base damage read the same for
four types against one PIDGEY, which does not settle it.

**Left as it is:** CYNDAQUIL (memory only) knows TACKLE, THUNDERSHOCK and EMBER, on Route 29 after the PIDGEY battle, every menu
closed, the driver alone on its target; the move-write probe's command file back to `off`.

## 2026-09-17 (the Crystal chat, same session) — which stats a move's damage uses; `strongest` weighs them too

**Built.** `strongest` also multiplies by the user's attack over the opponent's defense, or special attack over special
defense, by the move's type; `observe`'s party and battlers carry `stats`. The move-write probe gained `hold <address>
<value>` lines. Measurements: `crystal/MEASURED.md`, "Which stats a move's damage uses, and where the stats are".

**How it was measured.** The summary's stats page against the party bytes (BELLSPROUT's told speed from special attack, which
CYNDAQUIL's did not). Then one TACKLE replayed per case with an opponent's or the user's stat held at 70 and its type byte set:
all seventeen type ids against a held defense, and both sides for NORMAL and ELECTRIC. **What went wrong on the way:** the
first holds, on the stats at C6C1-C6CA, changed nothing -- the game put the old values back within the frame -- so the
battler block's copies were held instead, which moved the damage.

**Left as it is:** `route29_after_run`'s CYNDAQUIL (memory only) with THUNDERSHOCK and EMBER, after two PIDGEY battles, every
menu closed, the driver alone on its target, the probe's command file at `off`.

## 2026-09-17 (the Crystal chat, same session) — the lead fainted: "Use next POKéMON?" and the party list, named

**Built** (`crystal.lua` only; `text.lua` untouched while the Emerald chat has it open). Crystal's battle question hook names
"Use next POKéMON?" (`next_pokemon`) and the party list in a battle (`party`, with the names), so `battle` stops on each with its
kind and the caller answers with `select`. Which answer `battle` should give itself waits for the shared file. Measurements:
`crystal/MEASURED.md`, "The lead fainted".

**How it went.** CYNDAQUIL walked poisoned to 3 HP, cured, into Route 31's grass; a PIDGEY's TACKLE fainted it and the game asked.
From a snapshot there: NO ran ("Got away safely!"), YES opened "Which PKMN?", BELLSPROUT sent out and the battle played to its
end.

**Seen, to align:** the Emerald chat's uncommitted `text.lua` adds a policy `effective` (the type chart, through a hook
`effectiveMove`) and keeps `strongest` as power times accuracy; this chat made Crystal's `strongest` itself weigh types and
stats. Once that is committed, Crystal's scoring moves behind `effectiveMove` and `strongest` goes back to its shared meaning.

**Left as it is:** Route 31 after that battle (memory only), BELLSPROUT out front of a fainted CYNDAQUIL until healed.

## 2026-09-17 (the Crystal chat, end of the session) — where Crystal's autoplay stands, for the next chat

**The user:** *"fine to stop here for now ? and il continue in another chat/tomorrow"*.

**Crystal now has** (vanilla V1.0; `crystal/MEASURED.md` for every reading): everything the last session's end listed, plus
`goto` (doors, mats, trainers read before they load, on foot, on the BICYCLE and surfing), the first scenario
(`autoplay/games/crystal/scenarios/trainer_sight_range.json`, 3 of 3), the key item and TM/HM pockets read whole, the POKéMON
menu as a list, the party's moves, PP, item, status and stats, badges, `movement`, battle questions named (`switch` answered
NO; `nickname`, `next_pokemon` and `party` stop `needs_choice`), `strongest` weighing the type table, the same-type bonus and
attack against defense, and the cheats `set_flag`, `heal`, `set_badge`, `set_move` and `set_status`.

**Open, in order:**
- **Align the policies.** The Emerald chat's uncommitted `text.lua` adds `effective` (hook `effectiveMove`) and keeps `strongest`
  as power times accuracy. Once it is committed, move Crystal's scoring (`strongestMoveSlot` in `crystal.lua`) behind
  `effectiveMove`, put `strongest` back to power times the accuracy byte, and say so in the README and here.
- Which answer `battle` gives "Use next POKéMON?" and the party list itself (`text.lua`'s `answer`, once the file is free).
- The whiteout; the switch question with OPTION's battle style set the other way; a replan after a bump in `goto`; stat
  stages; `advance_text` logging the PACK's description box once as it closes.

**Left as it is:** EmuHawk on vanilla Crystal V1.0 (port 7871) still running, its loader target
`dev-scripts/bizhawk-dev-loader-autoplay-crystal.target` at `none`; the Emerald chat's emulator also running. Snapshot
`session_end2_route31` (Route 31 at (14,14), on foot, CYNDAQUIL 19/19 and BELLSPROUT 20/20, both OK, no badges, the item and
ball pockets as before) beside this session's others in the gitignored `autoplay/states/crystal/`: `route30_don_battle_start_2party`,
`battle_don_party_menu_after_yes`, `battle_don_switch_question`, `battle_nickname_question`, `route31_cyndaquil_hp3`,
`battle_use_next_question`. Nothing is pushed. This chat's core, `mcpcall` and `scenario` were built from HEAD into its own
scratch folder; a new chat builds its own. To attach: put `autoplay/drivers/bizhawk/driver.lua` in that target, `restore`
`session_end2_route31`, and pass `-listen 127.0.0.1:7871` with its own `-log`.
