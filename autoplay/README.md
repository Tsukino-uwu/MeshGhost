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
| `select` | Choose an entry in the open menu by its text (`item`) or 0-based `index`: the driver presses toward it until the game's own cursor is on it, then holds confirm until the menu responds (`confirm: false` stops on it). Every leg ends on the game's state, never a frame count |
| `walk` | Walk 1-32 tiles `up`, `down`, `left` or `right`, one tile at a time, each ending when the game says the step is done. Stops early and says why: `blocked` (with what is on the refused tile), `map_changed` (a door or an edge), `dialogue_open`, `menu_open`, `left_overworld`; reports the tiles actually moved |
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
  `finished` (its last box is up and waits for a button, with no arrow). Absent when no message box
  is on screen.
- **`menu`** — a list menu that is open (the START menu, a YES/NO): `items` in order and `cursor`,
  0-based. List menus with their own cursor (the bag, the PC, shops) and battle menus are not read
  yet.
- **`screen_text`** — any other window's printed text, per window, top to bottom.
- **`local_map`** — `rows` of characters, 15 wide by 11 tall with you at the centre, and a `legend`
  for the symbols present: `@` you, `N` a character, `W` a warp, `#` collision set, `.` clear at your
  elevation, a hex digit for clear at another elevation, a letter per behaviour byte (listed in the
  legend by number), `:` beyond this map's own edge. Only in the overworld.
- **`nearby`** — the other characters: slot, local id, graphic, map `x`/`y`, and `dx`/`dy` from you.
- **`warps`** — every warp on the map: `x`, `y` and the map it leads `to`.
- **What the save has**, in an `observe` you call only (a press's, select's or walk's `before` and
  `after` leave it out):
  - **`party`** — per Pokémon: `slot`, `species` (and `species_id`), `nickname`, `level`, `hp`,
    `max_hp`, `stats`, `exp`, `held_item`, `moves` (`name`, `id`, `pp`), and `status_raw` (only 0,
    no status, is measured). `checksum_mismatch` instead of species and moves when the slot's
    encrypted data does not add up.
  - **`bag`** — the pockets that hold anything: `items`, `poke_balls`, `tms_hms`, `berries`,
    `key_items`, each a list of `item`, `id`, `quantity`.
  - **`money`**, **`badge_count`**, and **`badges`**: which of the trainer card's eight, numbered 1-8
    from the left.
- A byte whose character is not measured, or that draws nothing, reads as `{XX}`.

The driver reports each of `map`, `mode`, `dialogue` and `menu` changing as an event:
`map_changed`, `mode_changed`, `dialogue_changed` and `menu_changed` (open or closed).

## The run log

Every session writes `autoplay/runs/<time>.ndjson`: each tool call, and each segment labelled
**walked** or **reached**. A segment starts walked and becomes reached the moment a cheat or a restore
succeeds in it, with what did it — the play-game skill's "walked to X" versus "reached X", kept by
code rather than by memory. A failed or refused cheat changes nothing.

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
- Cheats write the save's data in memory: **an in-game save afterwards keeps them.**

## Drivers so far

- **BizHawk** (`drivers/bizhawk/driver.lua`), loaded through `dev-scripts/bizhawk-dev-loader.lua`: put
  the driver's absolute path in the instance's control file, and set `AUTOPLAY_GAME` (and
  `AUTOPLAY_PORT` when it is not 7870) in the environment the emulator starts with. It logs to
  `autoplay/runs/driver_bizhawk.log`. Game modules: `games/emerald.lua` (vanilla: position and
  warp from `emerald/probes/cmd_drive.lua`'s measurements, text and menus from
  `text_probe.lua`'s and `charset_probe.lua`'s, the map and `walk` from `map_probe.lua`'s and
  `step_probe.lua`'s, the party, bag, badges and their cheats from `party_bag_probe.lua`'s and
  `substruct_order_probe.lua`'s). **While a press, a select or a walk runs it holds the controller** — take it
  off the target when done.
- **Text costs top speed.** Reading text needs execute hooks, and any execute hook costs the
  emulator about a third of its unthrottled speed (344 frames/s without, 242-246 with, one instance,
  2026-09-16), however many there are. `AUTOPLAY_TEXT=0` in the emulator's environment leaves them
  out for a run that wants full fast-forward and no text.

## Running it

- **Tests** (from `autoplay/`): `go vet ./...` and `go test ./...`. The race detector needs a gcc Go
  can use; `dev-scripts/run-gotests-race.bat` says which one works here, and the same `CC` and `PATH`
  apply. `dev-scripts/run-gotests.bat` covers only the MeshGhost module, never this one.
- **In Claude Code**: `autoplay/.mcp.json` starts the core with `go run`, from the repo root. A
  session launched with `--mcp-config autoplay/.mcp.json` gets the tools as `mcp__autoplay__*`. The
  core logs to `autoplay/runs/core.log` (gitignored); stdout belongs to MCP.
- **Without an agent**: `go run ./cmd/mcpcall -calls '<JSON list of {name, arguments}>'` (from
  `autoplay/`) starts the core over stdio the way Claude Code does, waits for a driver, and prints
  each tool's answer.
- **CI**: `.github/workflows/autoplay.yml` — build, vet, race tests, `govulncheck`, inside this module.

## What stays out of the repo

`runs/` and `states/` are gitignored. A savestate carries game data and never enters the repo: a
scenario builds its state with cheats. Every capture goes to `dev-scripts/shots/<game>/`.
