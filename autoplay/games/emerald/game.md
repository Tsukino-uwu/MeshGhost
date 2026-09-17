# Emerald (vanilla): how to play it with autoplay's tools

**Read at the start of every session**, with `route.md` and `goals.json` beside it. Measured or observed only: each line
names the record it came from, and anything known about Emerald from anywhere else is only where to look. What the
driver reads and what each tool does: `autoplay/README.md`. The bytes behind them:
`adapters/emulator/pokemon/emerald/MEASURED.md`. The dated log: `agent_docs/phases/autoplay/emerald.md`.
**Kept under 8 KB: update facts in place, never append a diary.**

## A session

- `status`, then `goal`: `next` is the goal to play toward, and its `hints` names the heading of `route.md` to read.
  `goal` with the goal's `id` checks it again once you think it is met.
- **Keep to the story's path** (the user, 2026-09-17): no area a badge or SURF gates yet; a warp only to make a test
  situation, and that stretch is reached, not walked.
- **Make a snapshot before a hard fight** (a gym leader, a rival), with a `note` saying where and what comes next, and
  get past it on luck from there if it goes badly (the user, 2026-09-17). Never an in-game save.
- `run_skill` before a chain of calls: `trip` crosses maps and deals with what stops it; `heal` goes to a Center and
  heals. Call the tools yourself only for what a skill answered `no_rule` or `stopped` on.

## Moving

- **`trip` {map, x, y}**: `goto` running, `battle effective` with `forget strong_variety` on a trainer's `spotted` or a
  wild battle, `advance_text` on a message; it stops on a whiteout. From the story sessions' loop (run logs
  `2026-09-17_120845.522443` and `2026-09-17_131645.118278`).
- **When `goto` fails, look at the ground before trying again** (emerald.md, 2026-09-17): "no way on foot" on Route 110
  was two ground levels meeting only through tiles of 0, and "no route to WATTSON" was a floor switch on the only path.
  Both were found by printing the map's grid from the ROM through `exec`, not by more attempts. The same `exec` read of
  a header's connections (+0x0C) and warps (events at +4: the count at +1, the list at +8, 8 bytes each) names the maps
  ahead before walking; the warps it read on 0.26 matched `observe`'s (route.md, toward the fourth gym, 2026-09-17).
- **A trip that reads the same message on every try** (the sandstorm on 0.26) stops `no_rule` after three: trip to a
  tile a different way instead (route.md, toward the fourth gym).
- **`goto` walks over step-on event tiles**: Mauville's gym switches flip its barriers when a route crosses one. Walk
  round with `walk` legs (route.md, Mauville).
- **A story scene can take the controls mid-route**; `goto` then reads `no_response` and may set an exit aside.
  `advance_text`, then the trip again.
- **Avoid trainers' sight where a route allows** (the user, 2026-09-17): not fighting every trainer is faster. `goto`
  already prefers routes out of sight; rotating trainers turn toward a running player.
- **To talk to a walking character**, stand beside its path, face it and press as it passes (the user, 2026-09-17).
- **Poké Balls lying on the ground hold items**: pick them up (the user, 2026-09-17).

## Finding a building

- **By who is inside, not by trying doors** (emerald.md, 2026-09-17): a Center's nurse is graphics 58, a Mart's clerk
  83, a gym's templates are trainers (Mauville, checked against Slateport and Dewford). Misreading a warp list cost
  several doors in Slateport. The user: Centers, Marts and gyms look unique from outside, so a screenshot of the town
  says which door.
- In every Center entered so far the nurse is local 1, talked to across the counter from (7,4) (route.md lists them).

## Battles

- **`battle effective`**: neutral or super effective moves whenever one does damage (the user, 2026-09-17: *"its bad to
  use ineffective moves"*). **`forget strong_variety`**: keep strong damaging moves of different types, status moves go
  first, and NO to a new move is a choice.
- **Status and accuracy moves still have uses** against a type that resists the rest (the user, 2026-09-17): MAY's
  GROVYLE on Route 110 was beaten with MUD-SLAP three times, then TACKLE, on the third try from a snapshot, after five
  losses (two of them under `effective`). `battle manual` stops at every action menu for that.
- **A party of one hits a wall against a type it is weak to** (emerald.md, 2026-09-17): a second Pokémon is the answer.
  Only wild Pokémon can be caught; one at low HP or with a status is easier; never faint it (the user).
- **Heal only when the next hit would faint, then attack**; potions work best when they heal more than a hit takes
  (the user, 2026-09-17). `battle stop_hp_below` stops at the action menu for BAG, POTION, USE, the Pokémon's name.
  Gym leaders heal mid-fight too.
- **After a whiteout, go back** (the user, 2026-09-17): the player wakes below the last Center entered and is higher
  level for the next try. Exploring before a gym works too.

## Money and items

- A Mart: `talk` to the clerk, BUY, the item, Up in the quantity box, YES (MEASURED.md, "A Mart", 2026-09-17). SUPER
  POTIONs heal more and cost more; selling raises money, with no buying back; REPELs keep weaker wild Pokémon away (the
  user, 2026-09-17).
- **An HM taught from the field BAG** (run log `2026-09-17_172659.154119`): Start, `select` BAG, `press Right` twice
  (ITEMS to POKé BALLS to TMs & HMs; the driver has no `sequence`), `select` the HM by index, USE, `advance_text`, YES,
  and on the forget question `select` the move by name. In the field: face the rock, `press A`, YES.

## Not built yet

A catch through the battle's BAG (the nickname question is read from the decomp only); reading step-on event tiles; SELL
at a Mart; TMs taught; `forget` weighing a move's side effect (it dropped MUD-SLAP, which had won MAY's fight).
