# autoplay — a dev-only harness that lets an agent play games

**Never built by a MeshGhost release and never shipped.** A Claude Code agent uses it to play a game
on a dev instance: reach a state, hold it, repeat it, and later turn what worked into a scenario that
runs with no model at all. It is its own Go module (ADR 0071); the log is
`agent_docs/phases/phase13.md` for the plan and the shared core and `agent_docs/phases/autoplay/<game>.md`
for each game, and today's rules for playing are the `play-game` skill
(`.claude/skills/play-game/`).

## The shape

```
Claude Code --MCP (stdio)--> autoplay core --JSON lines (127.0.0.1)--> driver inside the game
```

- **The core** (`cmd/autoplay`) is game-blind. It offers the agent tools, checks each against what
  the connected driver announced it can do, and passes the driver's answers through unread.
- **A driver** is the small piece inside an emulator or game that carries out commands. One per kind
  of host; per-game knowledge (where things live in memory) sits in that driver's game modules. A
  driver is dev tooling, the same class as a probe: nothing that ships writes game state.
- **The link** between them is `autoplay/driver/driver.go`'s protocol, stated at the top of that file.
  One driver per core; the core listens on `127.0.0.1:7870` unless `-listen` names another port, and
  a second instance's handoff names its own.

## Tools so far

| Tool | What it does |
|---|---|
| `status` | Whether a driver is connected, and its hello: host, game, variant, build, capabilities, protected slots |
| `observe` | The driver's snapshot of the game |
| `press` | Hold buttons for 1-600 frames, then report what changed — the escape hatch, not the default |
| `wait` | Let 1-3600 frames pass with NO input, then report what changed. Never hold a button to wait |
| `select` | Choose an entry in the open menu by its text (`item`) or 0-based `index`: the driver presses toward it until the game's own cursor is on it, then holds confirm until the menu responds (`confirm: false` stops on it). On a grid menu (a battle's) it reaches the column first. Every leg ends on the game's state, never a frame count |
| `walk` | Move 1-32 tiles `up`, `down`, `left` or `right`, holding the direction the whole way the way a player does, each tile counted when the game starts its step; `run: true` runs where the save can (`ran` says whether it did). On a bike it rides, still stopping on the tile: the Acro Bike stops where released, and on the Mach Bike it lets go early by the tiles the bike will coast (`overshot` if it ever carries past). Stops early and says why: `blocked` (with what is on the refused tile and its `cause`: `solid`, `npc_in_way`, `one_way_edge` -- a ledge from the wrong side --, `missing_ability` with the `ability`, `off_map` or `unknown`; Emerald's), `map_changed` (a door or an edge), `spotted` (a trainer has begun coming for you: its `local_id` and how many tiles away, from the frame the step into its line begins; hand it to `battle`), `dialogue_open`, `menu_open`, `left_overworld`; `moved` counts the steps begun. Walk for precision, run for speed that still stops on its tile, a bike for distance (the play-game skill's `references/navigation.md`) |
| `goto` | To a tile `x`,`y` on this map by a planned route: straight legs over the map's own grid (collision, elevation, characters and warps closed, a ledge crossed only the way it hops -- Emerald's, down -- and never stood on, tall grass avoided where there is another way unless `cross_grass`), turning at speed, replanning when a step is refused. Tiles an unbeaten trainer looks at cost far more than grass, so a route crosses a trainer's line only where there is no other way, and `route_in_sight` names each one it had to. To a warp it goes in: onto stairs, onto a door mat or a truck's door and then the way out, or up into a town door from the tile below (`entered` names it; each game's measured kinds only). Tiles at elevation 0 (mats, stairs) are open from any level. Rides what the player is on, stopping exactly on the tile (`run` on foot). With `map` (Emerald), a tile on another map, on foot: the maps between are planned fewest first over the part of each map a walk covers from where it is entered (collision, elevation, ledges one way, no water), read from the game's own tables, so an exit counts only where that part reaches it; each crossed in turn, and after every arrival it plans again from where it stands; an exit it cannot reach is set aside and the maps planned again; `maps` lists those it stood on. Stops early for the same reasons `walk` does, `spotted` included, or `unreachable` with the reason |
| `talk` | To a character (`local_id`, or the nearest): a tile beside it, or across a counter, by `goto`'s route, planned again if it walked off, facing it, a tapped A, then `advance_text` to its end; returns its `log`, `talked_to` and `advance_text`'s outcome (or `goto`'s, if the walk stopped). Emerald |
| `battle` | Plays the battle on screen to its end in one call, a trainer's words before and after included: `policy` `strongest` (FIGHT, then the usable move with most power times accuracy), `effective` (that times the game's own type chart against the opponent and the same-type bonus, the log's choice listing what each move `weighed`; Emerald and Crystal, where Crystal's also weighs the stats the damage uses, refused where a module has not measured its chart) or `run`. Called straight after `spotted`, it waits while the trainer walks over; it turns both pages of the level-up box; it waits while the game's script still runs after the battle, and past a menu the game answers itself (Emerald's WALLY battle). A question inside the battle, where the module reads one (Crystal's), is never answered by a nudge: "change POKéMON?" is answered NO by both policies, and any other stops `needs_choice` with the `question` and its `kind` (Crystal's `nickname` after a catch, `next_pokemon` when the lead faints, `party` for the list YES opens: answer with `select`, then call `battle` again). Returns a `log` of every message and choice and ends `ended` (with money and the party), `needs_choice`, `menu_open` (a menu outside the battle, for `select`), or `stuck` with what it was waiting on |
| `advance_text` | Presses through the message on screen box by box, tapping A, and waiting a moment on a message that ends with no arrow so a menu coming up is never answered by accident; waits out a cutscene while the game's script runs. Stops `closed`, `menu_open` (with the menu, for `select`), `keyboard_open` (with the keyboard, for `type_text`), `clock_open` (with the clock, for `set_clock`), `battle_started`, or `stuck` -- at once, without pressing, on a screen it cannot read. Returns a `log` of the boxes |
| `type_text` | Types `text` on the game's on-screen keyboard (a naming screen) the way a player does: clears what is typed, then per character changes page, walks the game's own cursor to the key one step at a time and presses it, reading each typed byte back; `confirm` (default true) then chooses OK. Never presses after the last letter without `confirm` (Emerald's cursor goes to OK by itself on a full name). Returns `typed` as the game holds it and `confirmed` or `typed` |
| `set_clock` | Sets the clock on the game's clock screen (a new game's wall clock) to `hours` (0-23) and `minutes` the way a player does: holds the hands' direction, whichever way round is shorter, and lets go on the frame the game reads the time; `confirm` (default true) then answers the game's question YES. Returns `set` (the time, with its `period`) and `confirmed` or `set` |
| `screenshot` | The game frame, saved to `dev-scripts/shots/<game>/autoplay_<name>.png` and returned as an image |
| `events` | Events the driver reported since a sequence number |
| `snapshot` | Save the whole game state to `autoplay/states/<game>/<label>.State` — a named file, never a numbered slot, so no slot of anyone's is ever touched |
| `restore` | Load a named snapshot. **Marks the segment REACHED** |
| `cheat` | A kind the driver announced as `cheat:<kind>`, with its arguments. **Marks the segment REACHED**. A cheat that stays in effect (a noclip) is named in the answer's `persisting` and reaches every segment while it is on (The run log) |
| `exec` | Runs `code` in the driver's host -- Lua in BizHawk, for every game -- and returns `results` (what it returns) and `output` (what it prints); the escape hatch for a question no tool answers yet. The core writes a fresh token to `runs/exec_token_<port>.txt` when it starts (`-exec-token` names another file) and removes it when it stops, and the driver runs nothing whose token is not that file's. The code gets its own globals (the driver's are read through them, never written), `game` (the module) and `print`, and is stopped after 20,000,000 instructions. **Marks the segment REACHED**. Off in the scenario runner |
| `segment` | Close the current run segment and start a labelled one; returns the closed one as walked or reached |

## What observe reads

Everything past `frame`, `mode` and `location` is the game module's. Emerald, on the vanilla ROM only
(the hash it was measured on; `emerald/MEASURED.md`, 2026-09-16):

- **`dialogue`** — the message being shown: `box` (that box's text, lines split by `\n`),
  `box_index` of `boxes`, and `state`: `printing`, `waiting_for_button` (the red arrow), or
  `finished` (its last box is up and waits for a button, with no arrow). `recovered` when it was taken
  up from the printer mid-way or already finished (its `box_index` then counts from where that string was found;
  a field or battle message from its buffer's start). Absent when
  no message box is on screen.
- **`menu`** — the menu waiting for input: `items` in order and `cursor`, 0-based. The START menu and a
  YES/NO; a grid such as the bag's USE/GIVE/TOSS/CANCEL with `columns` (numbered row by row); a scrolling
  list such as the bag's items with `list: true`, every entry whether shown or scrolled off, and in the
  bag the open `pocket` (the `bag` field's names; Left and Right change it). In a battle, the action menu
  (`battle_action`: FIGHT, BAG, POKéMON, RUN) or the move menu (`battle_move`: the four slots, `-` for an
  empty one), with `columns: 2`. The new game's starter bag as `kind: starter`, its three species in ball order and
  `columns: 3`, so `select` takes a species by name. The bag inside a battle, the party menu and other lists (the PC, shops)
  are not measured yet.
- **`keyboard`** — the naming screen: `title` ("YOUR NAME?"), `text` so far and its `length`, `max_length`,
  `page` (`capitals`, `small` or `symbols`; Select cycles them), `cursor` (`column`, `row`), `on` (the key under
  the cursor, or `OK`; `on_button_row` for the page and BACK buttons), `keys` (the page's rows as drawn), and
  `ready` while it takes presses (`state_raw` otherwise). Only the player's name is measured, not a nickname's.
- **`clock`** — the wall clock's screen: `hours` (0-23), `minutes`, `period` (`AM` or `PM`, which the drawn sign follows
  a few frames later), `state` (`setting` while the hands move, `confirming` while "Is this the correct
  time?" asks, with its YES/NO in `menu`, `closing` once YES is chosen, `viewing` when the clock is looked at once set),
  and `turning` while the hands still move.
- **`screen_text`** — any other window's printed text, per window, top to bottom. Left out in a
  battle, where a menu's window still reads as shown after it is gone.
- **`battle`** — while `mode` is `battle`: `asking` (`action`, `move`, or absent while the battle
  plays out), `kind` (`wild` or `trainer`), and per battler `side` (`player` or `opponent`), `species`,
  `nickname`, `level`, `hp`,
  `max_hp`, `types` (its two type bytes by name, one when they read the same) and `moves` (`name`, `pp`, `type`, `power`, `accuracy`); `type_flags_raw` and
  `outcome_raw` (1 after a win, 2 after a loss, 4 after running away, 7 after WALLY's catch). Single battles only are measured.
- **`local_map`** — `rows` of characters, 15 wide by 11 tall with you at the centre, and a `legend`
  for the symbols present: `@` you, `N` a character, `W` a warp, `#` collision set, `.` clear at your
  elevation, a hex digit for clear at another elevation, a letter per behaviour byte (listed in the
  legend by number), `!` a tile an unbeaten trainer looks at (stepping or standing there starts its
  battle), `:` beyond this map's own edge. Only in the overworld.
- **`nearby`** — the other characters: slot, local id, graphic, map `x`/`y`, `dx`/`dy` from you, `facing`
  (`down`, `up` or `right`; any other value as `facing_raw`) and `movement_type_raw`. A trainer carries
  `trainer`: `range` in tiles, `sees` (every way it turns; all four where its turning is not measured),
  `beaten` and its `flag`.
- **`warps`** — every warp on the map: `x`, `y`, the map it leads `to`, and its tile's `collision`,
  `elevation` and `behaviour` (how it is entered: `goto`'s row above).
- **What the save has**, in an `observe` you call only (a press's, select's or walk's `before` and
  `after` leave it out):
  - **`party`** — per Pokémon: `slot`, `species` (and `species_id`), `nickname`, `level`, `hp`,
    `max_hp`, `stats`, `exp`, `held_item`, `moves` (`name`, `id`, `pp`, `base_pp`, `type`, `power`
    — 0 for a move that does no damage, `accuracy`, and `description`, the effect text the summary
    shows), and `status_raw` (only 0,
    no status, is measured). `checksum_mismatch` instead of species and moves when the slot's
    encrypted data does not add up.
  - **`bag`** — the pockets that hold anything: `items`, `poke_balls`, `tms_hms`, `berries`,
    `key_items`, each a list of `item`, `id`, `quantity`.
  - **`money`**, **`badge_count`**, and **`badges`**: which of the trainer card's eight, numbered 1-8
    from the left.
- A byte whose character is not measured, or that draws nothing, reads as `{XX}`; a measured
  formatting command in text reads as `{FC 13 38}`.
- **`mode`** — `overworld`, `battle`, or `not_overworld` for anything else.
- **`movement`** — in the overworld, `on_foot`, `mach_bike` or `acro_bike`.

The driver reports each of `map`, `mode`, `dialogue` and `menu` changing as an event:
`map_changed`, `mode_changed`, `dialogue_changed` and `menu_changed` (open or closed), and
`battle_input_changed` when a battle starts or stops waiting for an action or a move.

**Crystal**, on the vanilla V1.0 ROM only (its hash; `crystal/MEASURED.md`, 2026-09-17), reads less so
far, and reads its text straight off the screen's tile buffer, with no hooks:

- **`location`** — `map` (group.number), `x`, `y` and `facing`. The tile changes when a step ENDS, not
  when it begins.
- **`mode`** — `overworld`, `battle` (a wild one and a trainer's measured), or `not_overworld` (a full-screen menu such
  as the PACK, a door's map load, the title and main menu).
- **`dialogue`** — `box` (the lines in the message box) and `state`: `printing`, `waiting_for_button`
  (the ▼), or `finished` (the last box, no ▼). There is no `box_index`: the tile buffer shows one box.
  Right after a `restore`, a waiting box can read `printing` until its ▼ blinks back (16 frames).
- **`menu`** — a menu with a ▶ cursor: `items` and `cursor`, 0-based. The START menu, a YES/NO, the main
  menu, the PACK's item menu (USE / GIVE / TOSS / QUIT), and in a battle the action grid (`columns: 2`, FIGHT PKMN /
  PACK RUN), the move list and a ball's USE / QUIT. The PACK's item, key item and ball pockets are read whole, scrolled
  off or not, in or out of a battle: `list: true`, `pocket` (`items`, `key_items`, `balls`), every entry and CANCEL in
  `items`, their `quantities` (not in the key item pocket, which has none), the `cursor` into the whole list, and the box
  under it as `description` (so `select` reaches any entry). The TM/HM pocket is read whole the same way (`tms_hms`), its
  `items` named TM01 or HM07 and each one's move, as the rows draw it, in `moves`. The POKéMON menu reads as `party: true` with the party's names
  and CANCEL, so `select` takes a name; the menu under a name (STATS / SWITCH / MOVE / ITEM / CANCEL) reads as drawn.
- **`screen_text`** — `row` and `text` for every other row holding words, only while the font is in the
  tiles (a Pokémon's picture reuses them; `crystal/MEASURED.md`, "Which font is loaded").
- **`local_map`** — 15 by 11 around the player: `@` you, `N` a character, `W` a warp, `S` a sign, `#`
  collision 0x07, `.` 0x00, `:` past this map's edge, `!` a tile an unbeaten trainer looks at the way it faces now,
  and a letter per other collision byte with what it did when measured (0x15 trees, 0x18 tall grass, 0x29 water, 0x71
  a door, ledges).
- **`nearby`** — each character: `slot`, `map_object`, `graphics_id`, `x`/`y`, `dx`/`dy`, `facing`,
  `movement_type_raw`; a trainer carries `trainer`: `range`, `beaten` and its `flag` (one trainer walked, range 3).
- **`warps`** — `x`, `y`, the map it leads `to` and `to_warp`, the destination's warp number from 1, and its tile's
  `collision_raw` (0x71 a door, stepped onto; 0x70 a house's mat, entered by a press down on it).
- **`extras.script_running_raw`** — 255 while a script has the controls: a message, a menu, a scene, a
  wild encounter, or a picture waiting for a button with no box on screen; 1 from the step into a trainer's sight
  until the map reloads after its battle, 2 from A on a trainer; 0 walking (9 a turn, 5 a door).
- **`battle`** — while `mode` is `battle`: `asking` (`action`, `move`, or absent) and `battlers`, each with `side`
  (`player`, `opponent`), `species` (and `species_id`), `nickname`, `level`, `hp`, `max_hp`, `types`, `stats` and `moves` (`name`, `id`,
  `pp`, `base_pp` -- the maximum drawn --, `type`, `power`, and `accuracy_raw`, a byte whose scale is not measured:
  held at 0 the move missed, and the table's 242 both hit and missed). `kind` (`wild`, `trainer`); in a trainer's
  battle `opponent_party_count` and `opponent_party_index`. A battler is absent until its Pokémon is sent out. One wild
  battle and one trainer's measured.
- **What the save has**, in an `observe` you call only: **`party`** (per Pokémon `slot`, `species` and `species_id`,
  `nickname`, `level`, `hp`, `max_hp`, `exp`, `held_item`, `status_raw` and `status` (`OK` for 0, `PSN` for 8; others raw), `stats` (`attack`, `defense`, `speed`, `sp_atk`, `sp_def`) and
  `moves` with `name`, `id`, `pp`, `base_pp`, `type`, `power` and `accuracy_raw`; two slots measured), **`money`**, and
  **`bag`** with the item, key item and ball pockets that hold anything (`item`, `id`, and `quantity` but for key items),
  and **`tms_hms`** (each TM or HM held, with its count), **`badge_count`** and **`badges`** (Johto's, numbered 1-8 as
  the trainer card draws them). Kanto's badges are not read yet.
- **`movement`** — in the overworld, `on_foot`, `bicycle` or `surfing` (any other state as `state_raw_N`).
- Not yet: a trainer that turns. The events are
  `map_changed`, `mode_changed`, `dialogue_changed`, `menu_changed` and `battle_mode_raw_changed`.
- Its tools: `walk` (on foot, on the BICYCLE, which stops on its tile as walking does, or surfing, whose steps are walking's; `run` walks and says `ran: false`, since Crystal has no running
  shoes; a door or a map edge answers once the player stands on the new map; `blocked` names a
  character in the way; `script_started` when a step starts a scene or an encounter; `spotted` with the
  trainer's `map_object` and `tiles_away` on the frame one sees the player), `select`, `advance_text`, `battle`
  (`strongest` scores power times the accuracy byte; `effective` times that by the game's type table against the opponent's
  types, half again for a move of the user's own type, and the user's attack over the opponent's defense -- special attack
  over special defense for FIRE, WATER, GRASS, ELECTRIC, PSYCHIC, ICE, DRAGON and DARK --, each move's score in the log's
  choice; called after `spotted` it waits while the trainer walks over; it
  presses A on the level-up stats box and on a battle's waits with no ▼; `ended` adds `outcome_raw`, 0 after a win and
  2 after running, `money`, `party_count` and a `party` entry per Pokémon; in a battle, the question "Will A change
  POKéMON?" is answered NO; the nickname after a catch, "Use next POKéMON?" and the party list after it stop
  `needs_choice`), `goto` (on foot; open tiles are the
  collision bytes a step was measured onto, 0x00 and 0x18 grass, and a refusal names any other byte on the map as not
  measured; trainers' lines are read from every trainer on the map, loaded or not, the way its movement type was seen
  standing (6 down, 7 up, 8 left) or every way; a door is stepped onto and a mat pressed down on; surfing, it keeps to the
  water (0x29) and takes land only as the target, a step ashore; it answers
  `map_changed` once the player stands on the new map), and the `warp`, `give_item` and `set_flag` cheats.

## The run log

Every session writes `autoplay/runs/<time>.ndjson`: each tool call, and each segment labelled
**walked** or **reached**. A segment starts walked and becomes reached the moment a cheat or a restore
succeeds in it, with what did it — the play-game skill's "walked to X" versus "reached X", kept by
code rather than by memory. A failed or refused cheat changes nothing. **A cheat still in effect** -- one the
driver lists in `persisting`, in its hello or a cheat's answer -- reaches the segment any call is made in, and a
segment begun while it is on begins reached (`cheat:noclip (still on)`), across core restarts too.

A core started with `-resume <that file>` carries it on instead of starting one: the open segment keeps
its label and its claim, rebuilt from the file. `mcpcall` starts a core per invocation, so a run driven
through it passes `-resume` every time (the `segment` tool's answer names the file); Phase 1's acceptance run
was one file across 58 cores.

## Scenarios

What an agent explored once, replayed with no model: a JSON file of tool calls, each with what its answer
must say (`scenario/`, run by `cmd/scenario`). The runner starts the core's own server in its process, the
driver connects to it as to any core, and every step goes through the same tools, so the run log labels
each run's `setup` and `steps` as their own segments, walked or reached.

- **A step** is `{tool, args, note, expect}`: `expect` is a list of `{path, <operator>}` on the tool's
  answer, and every one must hold. A path is keys and indices joined by dots (`after.location.x`, `log.0.text`),
  and `key[field=value]` picks an array's first element whose field reads value
  (`after.nearby[local_id=3].trainer.range`). Operators: `equals`, `not_equals`, `one_of`, `exists`, `min`,
  `max`, `contains`. A step with `error` instead expects the tool to refuse, with that text in the refusal.
- **Strict on purpose**: an unknown field, an expectation with no operator, or a tool the server lacks is
  refused before anything runs, since a misspelled check would pass forever. `restore` and `snapshot` are
  refused too: a scenario makes its situation with cheats.
- **A run stops at its first failed step**, and the scenario at its first failed run unless `-all`. Exit 0
  when every run passed, 1 when one failed, 2 when nothing ran (a file that does not load, no driver, another
  game or variant connected).
- **Scenarios so far**: `games/emerald/scenarios/trainer_sight_range.json` -- RICK's sight on route 0.17, from
  `emerald/MEASURED.md` (2026-09-17): cheats clear his defeat flag and warp three tiles above him, 120 frames
  pass with no script started, and the step to two above answers `spotted`, local id 3, two tiles away.
  `games/crystal/scenarios/trainer_sight_range.json` -- Bug Catcher Don's sight on Route 30, from `crystal/MEASURED.md`
  (2026-09-17): cheats warp four tiles below him, heal the party and clear his defeat flag (in that order: cleared with
  the player in his line, he starts at once), 120 frames pass with no script, the step to three below answers `spotted`,
  map object 4, three tiles away, and `battle strongest` plays his battle to `ended` so the next run starts clean (about
  1.5 minutes a run at normal speed).
  `games/emerald/scenarios/stuck_classifier.json` -- why a step was refused, from `emerald/MEASURED.md` (2026-09-17): warps
  below a wall, below a ledge, onto a shore and beside a beaten RICK; `walk` answers `blocked` with `cause` `solid`,
  `one_way_edge`, `missing_ability` (`surf`) and `npc_in_way`, and, after A on RICK, `dialogue_open` (3 of 3, and failing
  at its step with one expectation broken).
  `games/tevi/scenarios/cell_right_wall.json` -- the Bandit Base cell's right wall, from `adapters/tevi/MEASURED.md`
  (2026-09-17): a teleport onto the cell's floor, 30 frames standing, and two 60-frame holds of `XAxis+` that the wall stops
  at x 17040-17080 (3 of 3, and failing at its step with one expectation broken). The plan's Phase 6 acceptance.
- Not built yet: a `speed` setting, expectations on a MeshGhost adapter's own log, waiting on an event.

## Cheats so far

- **Emerald `warp`** `{map: "G.N", x, y}`: the game's own map load (the writes `cmd_drive.lua`
  measured). Refused outside vanilla's overworld callback. It answers once the game has left the
  overworld and come back on the target map (`done`, and the frames it took) — **the screen is still
  fading in at that moment**, so wait before judging a picture; the fade's length is not measured.
- **Emerald `give_item`** `{item, quantity}`: `item` is a name as the bag shows it (case ignored) or an
  id; `quantity` 1-99, default 1. It adds to that item's stack in the pocket the game files it under,
  or starts one, and `report` says `had` and `now`. Refused past 99 in one stack, and outside the
  overworld.
- **Emerald `set_flag`** `{flag, value}`: one story flag on or off (`value` defaults to true), ids 1-2399;
  `report` reads it back. Only the badge flags are measured: badge N is flag 2150 + N (0x866 + N).
  Refused outside the overworld.
- **Emerald `register_item`** `{item}`: the item SELECT uses (by name or id; the bag must hold it). A bike
  registered, `press` Select gets on or off it; with the other bike registered, one press gets off and the
  next gets on. Refused outside the overworld.
- **Emerald `noclip`** `{on}` (default true): kept in effect every frame until turned off or the driver unloads, with
  `probes/noclip.lua`'s mechanism: collision cleared on the grid within 6 tiles of the player (not the map's border), and
  every other character moved to an elevation the player is not on. Off puts back every tile and elevation still as it
  left them (`report` counts them). Walked through route 0.16's collision tile at (5,1) and through RICK on route 0.17
  (2026-09-17).
  Water, ledges and one-way tiles are not affected; `goto` plans over the grid as it reads, so only nearby walls are
  open to it. A snapshot taken while it is on keeps the cleared tiles. Refused outside the overworld.
- **Crystal `give_item`** `{item, quantity}`: `item` a name as the PACK draws it (case ignored) or an id; quantity 1-99.
  Only items the game files in the item pocket (their attribute entry's pocket byte reads 01, as POTION's and ANTIDOTE's
  do), the ball pocket (03, as POKé BALL's), the key item pocket (02, as BICYCLE's: quantity 1, once) or the TM/HM pocket
  (04: TM01-TM50, HM01-HM07, a count each); adds to the entry
  or starts one; refused past 99, past the pocket's entries (20, 12, 25), and outside the overworld. `report` reads it
  back.
- **Crystal `warp`** `{map: "G.N", x, y}` (0-255 each): the game's own map load (`crystal/probes/goto_map.lua`'s writes),
  refused outside the overworld or while a script has the controls (any wScriptRunning but 0: written during a trainer's
  words, the load waited for the whole battle); `done` once the target map runs, and `report` reads the map and tile back.
- **Crystal `set_flag`** `{flag, value}`: one event flag on or off (`value` defaults to true), ids 0-2047; `report` reads it
  back. Only trainers' defeat flags are measured (`nearby` names each trainer's `flag`). Refused outside the overworld.
  **A defeat flag cleared with the player standing in that trainer's line starts the trainer's approach at once**, with no
  step: warp out of the line first.
- **Crystal `heal`** `{}`: every Pokémon in the party to its max HP, each move's PP to its maximum and the status byte to 0
  (OK), as the POKéMON screen then draws; `report` reads the party back. Refused outside the overworld and on a raised PP
  byte (not measured).
- **Crystal `set_badge`** `{badge, value}`: Johto badge 1-8 on or off (`value` defaults to true), numbered as the trainer
  card draws them; `report` reads the byte back. Refused outside the overworld.
- **Crystal `set_move`** `{slot, move_slot, move}`: a party Pokémon's move slot (1-4) to a move by name or id, its PP to the
  move's maximum; it does not check whether the Pokémon could learn it. A field move written this way shows in the party
  menu (SURF did, and needed badge 4 to be used). Refused outside the overworld.
- **Crystal `set_status`** `{slot, status}`: `OK` or `PSN`, the values the POKéMON menu was seen to draw. A poisoned Pokémon
  loses 1 HP about every fourth step on foot and faints at 0 ("CYNDAQUIL fainted!", which stops `walk` and `goto`).
  Refused outside the overworld.
- **TEVI `teleport`** `{x, y}`: the player's position in world units, as `observe`'s location reads them, the velocity zeroed;
  answers 10 frames later with `held` (the position read back is the one asked for). Only in play; one made during a restore's
  fade-in did not hold, so `restore` answers after the fade.
- Cheats write the save's data in memory: **an in-game save afterwards keeps them.**

## Drivers so far

- **BizHawk** (`drivers/bizhawk/driver.lua`), loaded through `dev-scripts/bizhawk-dev-loader.lua`: put
  the driver's absolute path in the instance's control file, and set `AUTOPLAY_GAME` (and
  `AUTOPLAY_PORT` when it is not 7870) in the environment the emulator starts with. It logs to
  `autoplay/runs/driver_bizhawk.log`, or `driver_bizhawk_<game>_<port>.log` on another port, so a second
  instance never shares a log. Game modules: `games/emerald.lua` (vanilla: position and
  warp from `emerald/probes/cmd_drive.lua`'s measurements, text and menus from
  `text_probe.lua`'s, `charset_probe.lua`'s and `list_menu_probe.lua`'s, the map and `walk` from `map_probe.lua`'s and
  `step_probe.lua`'s, the party, bag, badges and their cheats from `party_bag_probe.lua`'s and
  `substruct_order_probe.lua`'s), and `games/crystal.lua` (vanilla V1.0: position, mode, `walk`, warps, text
  and menus from `crystal/probes/autoplay_state_probe.lua`'s, `autoplay_text_probe.lua`'s and
  `autoplay_charset_probe.lua`'s measurements). **While a press, a select or a walk runs it holds the controller** — take it
  off the target when done.
- **What the driver adds for every game**: `exec`, and two optional module functions -- `game.tick()`, run every frame
  whether or not a core is connected (Emerald's noclip lives there, so it survives `mcpcall` restarting the core), and
  `game.persisting()`, the cheats still in effect, sent in the hello and in every cheat's answer.
- **`select` waits for the game to see a release** where the module can tell (`game.inputReleased`):
  Crystal's START menu looks at the buttons only every few frames, and a 2-frame release between cursor
  moves was never seen, so the held button never moved the cursor again.
- **`battle` and `advance_text` are one machine for every game** (`drivers/bizhawk/text.lua`, out of
  `emerald.lua` since 2026-09-17): it decides when to press, and each game module hands it hooks for what
  it measured -- the message on screen, the battle menu and its cursor, whether a script still runs. The
  driver loads it and calls each module with it (`local lib = ...`); the hook list is at the top of the file.
- **`goto` is one program for every game** (`drivers/bizhawk/route.lua`, out of `emerald.lua` since 2026-09-17): it
  plans the route -- what a step, a turn, grass and a trainer's line cost -- and rides it, holding, turning, letting go
  and planning again after a bump; each game module hands it hooks for what it measured: which tiles are open, when a
  step begins or is refused, how a bike coasts, how each warp is entered. The hook list is at the top of the file;
  both modules supply them, and Crystal's also says when a warp is still under way (`arriving`). A tile may be one-way (a
  ledge). `goto` to another map (`travel`) and `talk` are there too, on hooks only Emerald's module supplies so far: any map's
  size and exits, a tile of any map, the characters, the facing, whether an A was taken.
- **Programs stop when nothing changes.** `walk`, `goto`, `select`, `battle` and `advance_text` run in the
  driver a frame at a time and end on the game's state; `battle` and `advance_text` press A once after
  3 seconds with no change -- only in a battle or on a message they can read -- retry a press the game
  ignored, and answer `stuck` after 3 of those, so a call never sits for minutes. A battle animation the module
  reports (`animationPlaying`; Emerald's is measured) counts as change, for up to 600 frames: STRING SHOT's runs 228
  frames with nothing else moving. Emerald's also counts a battle controller at work, unless it waits on a message's arrow
  or a menu: a wild battle's intro ran 218 frames so, and a nudge had landed in it. Emerald's module learns text as it prints, and a message already under way -- or finished, its
  window still put and drawn in -- when it was reloaded or a snapshot restored is taken up from the game's text printer, marked
  `recovered` (Crystal's
  reads whatever is on screen).
- **Text costs top speed on Emerald.** Reading text there needs execute hooks (Crystal's needs none), and any execute hook halves the
  emulator's unthrottled speed, however many there are (one instance, a core connected: 818
  frames/s without, 410-416 with; `emerald/MEASURED.md`, 2026-09-16). `AUTOPLAY_TEXT=0` in the
  emulator's environment leaves them out for a run that wants full fast-forward and no text. With no
  core running, the driver retries once a second, which costs little (802.5 with no hooks).
- **BepInEx (TEVI)** (`drivers/bepinex/`: `Link.cs`, the link for any BepInEx game; `tevi/`, the plugin), the plan's
  Phase 6 (`agent_docs/phases/autoplay/tevi.md`). A plugin of its own, never inside MeshGhost's adapter: build with
  `dotnet restore --source <the local NuGet cache>` once, then `dotnet build -c Release --no-restore` in `tevi/` (it
  references the Steam install's game assemblies; `-p:TeviManaged=<folder>` for another), copy
  `MeshGhostAutoplayTevi.dll` and `.pdb` into the install's `BepInEx\scripts\`, and put `meshghost-autoplay.txt` there
  with `port=<the core's>` and `repo=<this repo's root>` -- no file, no connection. ScriptEngine reloads it when the DLL
  changes. It logs to `autoplay/runs/driver_bepinex_tevi_<port>.log`. Tools: `observe` (`mode`, `location` with area,
  room and position, `player`, the save list's `menu` by page, row and slot, and `save`), `wait`, `press` (the game's
  own Rewired actions by name, an axis with a sign: `Confirm`, `XAxis+`), `screenshot` (the game's own frame);
  events `mode_changed`, `area_changed`, `room_changed`. An `observe` the agent calls also reads what is around the player
  from the game's state (`Surroundings.cs`): `player` physics, `view` (the camera's edges; a pixel is a world unit), a
  27-by-17-tile `local_map` of the game's collision grid (`#` byte 1, `.` 0, `=` 255, a platform stood on from above, slopes
  by byte range) with characters, items and the elements a player meets drawn over it, `nearby`, `elements`, `items`,
  `projectiles`, and `dialogue` (section, line of lines, speaker, the whole line). `snapshot` is the game's own save to
  slot 39 (in the shadow below) copied to the core's `.State` path; `restore` copies it back, points the recent slot at it
  and reloads, answering once the area, the camera and the fade-in are done (272 frames in the cell).
- **TEVI's save guard.** From the moment a core first connects until the game exits, TEVI's save folder is a shadow copy
  (`autoplay/states/tevi/shadow/`, copied fresh as it arms): every save read and write goes there, the real folder is
  never written, and the autosave is held -- the unmodded saves never change while autoplay may have changed the game
  (the user, 2026-09-17). A shadow rather than a refusal: a new game reads back the slot pointer it just wrote, and a
  refused write loaded the player's autosave instead (`agent_docs/pitfalls/by-lesson.md`). No `repo` in the config, no
  connection. It survives a hot reload; a change to its code needs a game restart. Restart TEVI to play with saving again.
  `observe`'s `menu` also reads the title's main menu, Custom Game (`ticked`) and the difficulty list (`items`, `cursor`).

## Running it

- **Tests** (from `autoplay/`): `go vet ./...` and `go test ./...`. The race detector needs a gcc Go
  can use; `dev-scripts/run-gotests-race.bat` says which one works here, and the same `CC` and `PATH`
  apply. `dev-scripts/run-gotests.bat` covers only the MeshGhost module, never this one.
- **In Claude Code**: `autoplay/.mcp.json` starts the core with `go run`, from the repo root. A
  session launched with `--mcp-config autoplay/.mcp.json` gets the tools as `mcp__autoplay__*`. The
  core logs to `autoplay/runs/core.log` (gitignored); stdout belongs to MCP.
- **Without an agent**: `go run ./cmd/mcpcall -calls '<JSON list of {name, arguments}>'` (from
  `autoplay/`) starts the core over stdio the way Claude Code does, waits for a driver, and prints
  each tool's answer. A second instance passes its own `-listen 127.0.0.1:<port>` and `-log runs/<name>.log`;
  a run spread over many invocations passes `-resume runs/<its file>.ndjson` to each (The run log). For many
  calls, build both once (`go build -o <dir>/autoplay.exe ./cmd/autoplay`, the same for `./cmd/mcpcall`) and pass
  `-core <dir>/autoplay.exe`: `go run` compiles on every invocation.
- **Scenarios**: `go run ./cmd/scenario <files or folders>` (from `autoplay/`), with the driver's port free:
  the runner listens on it itself (`-listen` for another). `-repeat N` overrides the file's count.
- **CI**: `.github/workflows/autoplay.yml` — build, vet, race tests, `govulncheck`, inside this module.

## What stays out of the repo

`runs/` and `states/` are gitignored. A savestate carries game data and never enters the repo: a
scenario builds its state with cheats. Every capture goes to `dev-scripts/shots/<game>/`.
