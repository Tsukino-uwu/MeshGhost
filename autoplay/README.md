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
| `screenshot` | The game frame, saved to `dev-scripts/shots/<game>/autoplay_<name>.png` and returned as an image |
| `events` | Events the driver reported since a sequence number |
| `snapshot` | Save the whole game state to `autoplay/states/<game>/<label>.State` — a named file, never a numbered slot, so no slot of anyone's is ever touched |
| `restore` | Load a named snapshot. **Marks the segment REACHED** |
| `cheat` | A kind the driver announced as `cheat:<kind>`, with its arguments. **Marks the segment REACHED** |
| `segment` | Close the current run segment and start a labelled one; returns the closed one as walked or reached |

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

## Drivers so far

- **BizHawk** (`drivers/bizhawk/driver.lua`), loaded through `dev-scripts/bizhawk-dev-loader.lua`: put
  the driver's absolute path in the instance's control file, and set `AUTOPLAY_GAME` (and
  `AUTOPLAY_PORT` when it is not 7870) in the environment the emulator starts with. It logs to
  `autoplay/runs/driver_bizhawk.log`. Game modules: `games/emerald.lua` (vanilla, using only
  addresses `emerald/probes/cmd_drive.lua` already measured). **While a press runs it holds the
  controller** — take it off the target when done.

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
