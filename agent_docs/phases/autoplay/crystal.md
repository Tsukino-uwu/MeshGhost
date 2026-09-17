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
