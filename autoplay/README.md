# autoplay — a dev-only harness that lets an agent play games

**Never built by a MeshGhost release and never shipped.** A Claude Code agent uses it to play a game
on a dev instance: reach a state, hold it, repeat it, and later turn what worked into a scenario that
runs with no model at all. It is its own Go module (ADR 0071); the log is
`agent_docs/phases/phase13.md`, and today's rules for playing are the `play-game` skill
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
| `walk` | Move 1-32 tiles `up`, `down`, `left` or `right`, holding the direction the whole way the way a player does, each tile counted when the game starts its step; `run: true` runs where the save can (`ran` says whether it did). On a bike it rides, still stopping on the tile: the Acro Bike stops where released, and on the Mach Bike it lets go early by the tiles the bike will coast (`overshot` if it ever carries past). Stops early and says why: `blocked` (with what is on the refused tile), `map_changed` (a door or an edge), `spotted` (a trainer has begun coming for you: its `local_id` and how many tiles away, from the frame the step into its line begins; hand it to `battle`), `dialogue_open`, `menu_open`, `left_overworld`; `moved` counts the steps begun. Walk for precision, run for speed that still stops on its tile, a bike for distance (the play-game skill's `references/navigation.md`) |
| `goto` | To a tile `x`,`y` on this map by a planned route: straight legs over the map's own grid (collision, elevation, characters and warps closed, ledges closed, tall grass avoided where there is another way unless `cross_grass`), turning at speed, replanning when a step is refused. Tiles an unbeaten trainer looks at cost far more than grass, so a route crosses a trainer's line only where there is no other way, and `route_in_sight` names each one it had to. To a warp it goes in: onto stairs, onto a door mat or a truck's door and then the way out, or up into a town door from the tile below (`entered` names it; Emerald's measured kinds only). Tiles at elevation 0 (mats, stairs) are open from any level. Rides what the player is on, stopping exactly on the tile (`run` on foot). Stops early for the same reasons `walk` does, `spotted` included, or `unreachable` with the reason |
| `battle` | Plays the battle on screen to its end in one call, a trainer's words before and after included: `policy` `strongest` (FIGHT, then the usable move with most power times accuracy) or `run`. Called straight after `spotted`, it waits while the trainer walks over; it turns both pages of the level-up box; it waits while the game's script still runs after the battle. Returns a `log` of every message and choice and ends `ended` (with money and the party), `needs_choice`, `menu_open` (a menu outside the battle, for `select`), or `stuck` with what it was waiting on |
| `advance_text` | Presses through the message on screen box by box, tapping A, and waiting a moment on a message that ends with no arrow so a menu coming up is never answered by accident; waits out a cutscene while the game's script runs. Stops `closed`, `menu_open` (with the menu, for `select`), `battle_started`, or `stuck` -- at once, without pressing, on a screen it cannot read (a naming keyboard, the starter bag). Returns a `log` of the boxes |
| `screenshot` | The game frame, saved to `dev-scripts/shots/<game>/autoplay_<name>.png` and returned as an image |
| `events` | Events the driver reported since a sequence number |
| `snapshot` | Save the whole game state to `autoplay/states/<game>/<label>.State` — a named file, never a numbered slot, so no slot of anyone's is ever touched |
| `restore` | Load a named snapshot. **Marks the segment REACHED** |
| `cheat` | A kind the driver announced as `cheat:<kind>`, with its arguments. **Marks the segment REACHED** |
| `segment` | Close the current run segment and start a labelled one; returns the closed one as walked or reached |

## What observe reads

Everything past `frame`, `mode` and `location` is the game module's. Emerald, on the vanilla ROM only
(the hash it was measured on; `emerald/MEASURED.md`, 2026-09-16):

- **`dialogue`** — the message being shown: `box` (that box's text, lines split by `\n`),
  `box_index` of `boxes`, and `state`: `printing`, `waiting_for_button` (the red arrow), or
  `finished` (its last box is up and waits for a button, with no arrow). `recovered` when it was taken
  up from the printer mid-way (its `box_index` then counts from where that string was found). Absent when
  no message box is on screen.
- **`menu`** — the menu waiting for input: `items` in order and `cursor`, 0-based. The START menu and a
  YES/NO; a grid such as the bag's USE/GIVE/TOSS/CANCEL with `columns` (numbered row by row); a scrolling
  list such as the bag's items with `list: true`, every entry whether shown or scrolled off, and in the
  bag the open `pocket` (the `bag` field's names; Left and Right change it). In a battle, the action menu
  (`battle_action`: FIGHT, BAG, POKéMON, RUN) or the move menu (`battle_move`: the four slots, `-` for an
  empty one), with `columns: 2`. The bag inside a battle, the party menu and other lists (the PC, shops)
  are not measured yet.
- **`screen_text`** — any other window's printed text, per window, top to bottom. Left out in a
  battle, where a menu's window still reads as shown after it is gone.
- **`battle`** — while `mode` is `battle`: `asking` (`action`, `move`, or absent while the battle
  plays out), `kind` (`wild` or `trainer`), and per battler `side` (`player` or `opponent`), `species`,
  `nickname`, `level`, `hp`,
  `max_hp` and `moves` (`name`, `pp`, `type`, `power`, `accuracy`); `type_flags_raw` and
  `outcome_raw` (1 after a win, 4 after running away). Single battles only are measured.
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
- **`mode`** — `overworld`, `battle` (a wild one measured), or `not_overworld` (a full-screen menu such
  as the PACK, a door's map load, the title and main menu).
- **`dialogue`** — `box` (the lines in the message box) and `state`: `printing`, `waiting_for_button`
  (the ▼), or `finished` (the last box, no ▼). There is no `box_index`: the tile buffer shows one box.
  Right after a `restore`, a waiting box can read `printing` until its ▼ blinks back (16 frames).
- **`menu`** — a menu with a ▶ cursor: `items` and `cursor`, 0-based. The START menu, a YES/NO, the main
  menu, and in a battle the action grid (`columns: 2`, FIGHT PKMN / PACK RUN) and the move list.
  Scrolling lists (the PACK's items) are not read yet.
- **`screen_text`** — `row` and `text` for every other row holding words, only while the font is in the
  tiles (a Pokémon's picture reuses them; `crystal/MEASURED.md`, "Which font is loaded").
- **`local_map`** — 15 by 11 around the player: `@` you, `N` a character, `W` a warp, `S` a sign, `#`
  collision 0x07, `.` 0x00, `:` past this map's edge, and a letter per other collision byte with what it
  did when measured (0x15 trees, 0x18 tall grass, 0x29 water, 0x71 a door, ledges).
- **`nearby`** — each character: `slot`, `map_object`, `graphics_id`, `x`/`y`, `dx`/`dy`, `facing`,
  `movement_type_raw`.
- **`warps`** — `x`, `y`, the map it leads `to` and `to_warp`, the destination's warp number from 1.
- **`extras.script_running_raw`** — 255 while a script has the controls: a message, a menu, a scene, a
  wild encounter, or a picture waiting for a button with no box on screen.
- Not yet: `movement`, `battle` (the battlers), trainer sight, and what the save has. The events are
  `map_changed`, `mode_changed`, `dialogue_changed`, `menu_changed` and `battle_mode_raw_changed`.
- Its tools: `walk` (on foot only; `run` walks and says `ran: false`, since Crystal has no running
  shoes; a door or a map edge answers once the player stands on the new map; `blocked` names a
  character in the way; `script_started` when a step starts a scene or an encounter), `select`,
  `advance_text`, and `battle` with `policy: "run"` only (its battlers and move data are not measured, so
  `strongest` is refused). No `goto` or cheats yet.

## The run log

Every session writes `autoplay/runs/<time>.ndjson`: each tool call, and each segment labelled
**walked** or **reached**. A segment starts walked and becomes reached the moment a cheat or a restore
succeeds in it, with what did it — the play-game skill's "walked to X" versus "reached X", kept by
code rather than by memory. A failed or refused cheat changes nothing.

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
- **`select` waits for the game to see a release** where the module can tell (`game.inputReleased`):
  Crystal's START menu looks at the buttons only every few frames, and a 2-frame release between cursor
  moves was never seen, so the held button never moved the cursor again.
- **`battle` and `advance_text` are one machine for every game** (`drivers/bizhawk/text.lua`, out of
  `emerald.lua` since 2026-09-17): it decides when to press, and each game module hands it hooks for what
  it measured -- the message on screen, the battle menu and its cursor, whether a script still runs. The
  driver loads it and calls each module with it (`local lib = ...`); the hook list is at the top of the file.
- **Programs stop when nothing changes.** `walk`, `goto`, `select`, `battle` and `advance_text` run in the
  driver a frame at a time and end on the game's state; `battle` and `advance_text` press A once after
  3 seconds with no change -- only in a battle or on a message they can read -- retry a press the game
  ignored, and answer `stuck` after 3 of those, so a call never sits for minutes. Emerald's module learns text as it prints, and a message already under way when it
  was reloaded or a snapshot restored is taken up from the game's text printer, marked `recovered` (Crystal's
  reads whatever is on screen).
- **Text costs top speed on Emerald.** Reading text there needs execute hooks (Crystal's needs none), and any execute hook halves the
  emulator's unthrottled speed, however many there are (one instance, a core connected: 818
  frames/s without, 410-416 with; `emerald/MEASURED.md`, 2026-09-16). `AUTOPLAY_TEXT=0` in the
  emulator's environment leaves them out for a run that wants full fast-forward and no text. With no
  core running, the driver retries once a second, which costs little (802.5 with no hooks).

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
