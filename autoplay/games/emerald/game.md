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
  wild battle, `advance_text` on a message; it stops on a whiteout (run log `2026-09-17_131645.118278`).
- **When `goto` fails, look at the ground before trying again** (emerald.md, 2026-09-17): "no way on foot" on Route 110
  was two ground levels meeting only through tiles of 0, and "no route to WATTSON" was a floor switch on the only path.
  Both were found by printing the map's grid through `exec`, not by more attempts. The header, event and tile bytes to
  read the maps and doors ahead, and the behaviours seen (0xD0 mud slope, 0x3B, 0x68 hole, 0x29 geyser): MEASURED.md,
  "Map headers, events and behaviours read by an unattended session". goto's "not an open tile from elevation N" was a
  collision tile: a neighbour from the grid went. `observe`'s `nearby` lists characters within about 10 tiles only.
- **A mud slope (behaviour 0xD0) is not walked up on foot**: the player slides back, and `goto` plans round it or
  answers `unreachable` (MEASURED.md, "A mud slope on 0.26"). The user: a MACH BIKE goes up them.
- **A warp tile of behaviour 101** (cave exits, the cable car stations) is left by stepping onto it, then `walk` Down
  and `press B` 60. After any door or warp, `press B` 60 before the next call: `goto`/`talk` answer "needs the overworld"
  during the fade (run log `2026-09-17_181542.300302.ndjson`).
- **A smashed rock is back after a whiteout** (run log `2026-09-17_175751.136021`): a trip answered "no way on foot"
  at 0.26 (19,101) until (19,100) was smashed again. **A trip reading the same message
  on every try** (0.26's sandstorm) stops `no_rule` after three: trip to a tile a different way.
- **`goto` walks over step-on event tiles**: Mauville's gym switches flip its barriers when a route crosses one. Walk
  round with `walk` legs (route.md, Mauville).
- **A story scene can take the controls mid-route**; `goto` then reads `no_response` and may set an exit aside.
  `advance_text`, then the trip again. A `goto` answering `no_response` just after a geyser landing at Lavaridge's gym
  (4.1 (2,14)) was two trainers' battles starting: `battle` played both (run log `2026-09-17_185825.337345.ndjson`).
- **Move through the overworld as fast as possible; skip trainers as much as possible** (the user, 2026-09-17): a
  trainer battle cannot be run from and is several Pokémon in a row, while a wild one can be run from -- prefer grass
  to a trainer's sight, and run from wild Pokémon when there are no REPELs, though trainers give more experience.
  `goto` weighs a tile in a trainer's sight as about 125 of grass; `trip` fights a trainer who spots the player and
  answers any other battle with `battle run_wild` (RUN in a wild one, `effective` in a trainer's; "Got away safely!",
  2026-09-17). Fight wild Pokémon yourself only when levels are wanted. Rotating trainers turn toward a running player.
- **To talk to a walking character**, stand beside its path, face it and press as it passes (the user, 2026-09-17).
- **Poké Balls lying on the ground hold items**: pick them up (the user, 2026-09-17).

## Finding a building

- **By who is inside, not by trying doors** (emerald.md, 2026-09-17): a Center's nurse is graphics 58, a Mart's clerk
  83, a gym's templates are trainers (Mauville, checked against Slateport and Dewford). Misreading a warp list cost
  several doors in Slateport. The user: Centers, Marts and gyms look unique from outside, so a screenshot of the town
  says which door.

## Battles

- **`battle effective`**: neutral or super effective moves whenever one does damage (the user, 2026-09-17: *"its bad to
  use ineffective moves"*). **`forget strong_variety`**: keep strong damaging moves of different types, status moves go
  first, and NO to a new move is a choice.
- **Status and accuracy moves still have uses** against a type that resists the rest (the user, 2026-09-17): MAY's
  GROVYLE on Route 110 was beaten with MUD-SLAP three times, then TACKLE, on the third try from a snapshot, after five
  losses (two of them under `effective`). `battle manual` stops at every action menu for that.
- **`effective` does not know abilities**: it chose MUD SHOT six times into a wild KOFFING's LEVITATE while poison
  fainted SWAMPERT, a whiteout inside a trip (run log `2026-09-17_181542.300302.ndjson`).
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
  user, 2026-09-17). In the quantity box `press Right`, then `press Down` twice, asked for 8; A, `advance_text`, YES,
  `advance_text`; leave with CANCEL, then QUIT (run logs `2026-09-17_174529.077127`,
  `2026-09-17_181542.300302.ndjson`).
- **A whiteout costs money** (7357 to 1910, run log `2026-09-17_175751.136021`) and the walk back.
- **An HM from the field BAG** (walked three times, last `2026-09-17_181542.300302.ndjson`): Start, `select` BAG, `press
  Right` twice (ITEMS to POKé BALLS to TMs & HMs; the driver has no `sequence`), `select` the HM by index (by name
  fails: TM/HM entries read with control codes, run log `2026-09-17_192410.553244.ndjson`), USE, `advance_text`, YES, `press A` twice (party screen),
  `advance_text`, YES, `advance_text` (needs_choice), `select` the move to forget by name, `advance_text`, `select` CLOSE BAG,
  `press B`. In the field: face the rock, `press A`, `advance_text`, YES, `advance_text`. After an HM was taught,
  two `press Left` reached ITEMS again. A field SUPER POTION: `select` it, USE, `press A` (party screen),
  `select` the Pokémon, `advance_text`; `select` CLOSE BAG failed on a two-entry list, `press B` twice closed it (run
  log `2026-09-17_185825.337345.ndjson`). **After an HM was taught the BAG opened on TMs & HMs, in battle too** (`select` SUPER
  POTION by name failed there): at `stop_hp_below`, `select` BAG, `press Left` twice (TMs & HMs to ITEMS), `select` SUPER POTION, USE, `press A`, then `battle` again
  (MAXIE, run log `2026-09-17_192410.553244.ndjson`).

## Not built yet

A catch through the battle's BAG (the nickname question is read from the decomp only); reading step-on event tiles; SELL
at a Mart; TMs taught; `forget` weighing a move's side effect (it dropped MUD-SLAP, which had won MAY's fight); abilities
in `effective`.
