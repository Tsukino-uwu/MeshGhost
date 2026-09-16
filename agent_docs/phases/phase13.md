# Phase 13 — Autoplay: a dev-only harness that plays games for mod and adapter testing

**A dated record, not current fact.** Each entry says what was true while it was written; paths and
numbers are left as they were. Current state lives in `status.md`; the roadmap entry in `plans.md`;
the instructions an agent follows while playing today in the `play-game` skill
(`.claude/skills/play-game/`).

**What this phase is.** A dev-only program, never built by a release and never shipped, that lets a
Claude Code agent play a game on its own: the model plans and code executes; knowledge lives in
files; cheats are first-class and every segment says whether it was walked or reached; and what the
agent explores once becomes a scenario that replays after every build with no model. A game-agnostic
core plus a thin driver per host, for any game, through whatever dev channel its host already has.

## 2026-09-16 — Phase 0: the plan checked against the repo; the proposal waits at the checkpoint

**Where it came from.** The user brought `autoplay-plan.md`, written in a Claude Desktop chat that
had seen only the public `playing.md`, with the instruction that the repo wins. Its precursor the same
day — `playing.md` becoming the `play-game` skill — is logged in `phase12.md`. Phase 0 was to verify
every concrete claim and propose a layout, a contract, what to reuse and the risks; nothing is built.

**The user's rulings while reviewing it (2026-09-16):**
- It is for ANY game, to help development; the first hosts are inputs, not limits.
- **Savestates never enter the public repo.** A needed state is made with cheats; a savestate is only
  a local, gitignored cache.
- **Where a host cannot capture its own frame, a window capture is fine**, and every capture is
  gitignored and never goes up on the public repo (recorded in `playing-rationale.md` and the skill).
- `autoplay/` sits at the repo root with its own `go.mod`; its MCP config lives inside `autoplay/`.
- It gets this phase; every new adapter always gets one, and a feature when the user says so
  (`phases/README.md`).

**What the plan had wrong or could not know**, each checked in the tree:
- **Hosts.** TEVI is a BepInEx 5 plugin on Mono (`environment.md`), not an injection; it already has
  ScriptEngine hot reload and a dev-cheats plugin with a toggle file
  (`adapters/tevi/devtools/MeshGhostTeviDevCheats/`). Pseudoregalia ships a UE4SS C++ mod, but its dev
  channel is UE4SS Lua, and a LuaSocket round trip from UE4SS Lua to a real core worked 2026-08-12
  (`pseudoregalia/VERIFIED.md`, Phase 7.2) — so a Lua driver there is proven feasible.
- **The rig.** The relay binary is `cmd/meshghost-relay` (shipped as `meshghost-server.exe`); `-loopback`
  and `meshghost-fakeadapter` exist. There is no MCP SDK in `go.mod`, and it is one module.
- **The BizHawk driver already half-exists**: `cmd_drive.lua` (Crystal and Emerald, 2026-09-16) is a
  command queue polled every 15 frames that idles when empty, with `hold`, `wait`, `shot`, `status`,
  warps, tile writes and items without menus. A play driver grows out of it.
- **Branching** contradicts `CLAUDE.md` (straight to `master`). **"Facts from decompilations are
  fine"** contradicts MEASURED OR OBSERVED ONLY (2026-09-13): a knowledge file's addresses name our
  evidence, and symbol tables never enter.
- **A tracked root `.mcp.json` is blocked** by the root-file allowlist, and Claude Code's docs describe
  a project `.mcp.json` at the project root, not in a subfolder — so the harness passes `autoplay/`'s
  config with `--mcp-config` (present in CLI 2.1.273), and interactive use needs that flag or a
  one-time local-scope registration kept in the user's own config.
- **"autoplay adapters" collides** with MeshGhost's adapters and with preflight, which treats any
  `*/documentation.md` as one; drivers is the proposed name.
- **Frame-timed `press {frames}`** is the pattern `_template/probes.md` retired on 2026-09-12 ("A driven
  leg is MEASURED, not timed"): a move ends on the game's own state, with a settle and a stuck escape.
- **The session loop needs a standing grant**: `CLAUDE.md` lets an agent start a game only after
  asking, and an `EmuHawk` appearing is the user's session signal.

**Measured on the way:** a headless `claude -p --output-format stream-json` run ends with a `result`
line carrying `num_turns` (the play-game trigger test: 42 and 15). The MCP Go SDK
(`github.com/modelcontextprotocol/go-sdk`, v1.8.0 of 2026-09-14) is licensed as a transition — MIT for
contributions not yet relicensed, Apache-2.0 for the rest — read from its own license text via
`gh api`; the badge says NOASSERTION. It is not in `licensing.md` yet and nothing of it is read or used.

**Proposed at the checkpoint — nothing decided until the user answers:**
- **Layout.** `autoplay/` with its own `go.mod`: root `go build|vet|test ./...`, the race shards and
  `govulncheck` stop at the module boundary, `release.yml` builds only the two shipped commands, and
  `stage-release.ps1` copies an explicit list — so nothing needs excluding. It gets its own
  path-filtered `autoplay.yml`; preflight's "root binaries vs Go source" must skip `autoplay/`, or
  every harness edit reads as a stale `meshghost.exe`. Inside: `cmd/autoplay` (the MCP server over
  stdio plus the driver listener), `scenario/` (the runner, no model), `drivers/<host>/`, tracked
  `games/<game>/` (route, variants, goals, skills, scenarios), and gitignored `runs/`, `states/` and
  captures. It imports nothing from the MeshGhost module, the way `meshghost-netsim` does.
- **Contract.** NDJSON over 127.0.0.1 with `{id, type, payload}` (the bridge's framing plus request ids,
  its 64 KiB line cap); the core listens on the instance's own port, named in the handoff and outside
  the relay and bridge ports, and the driver connects out and reconnects. `hello` declares host, game,
  build, capabilities, protected slots and the driver's own vocabulary (modes, events, blocked
  reasons), which the core treats as opaque. `act` returns a diff; a move ends on the game's state;
  `neutral` spams B/Start to a verified overworld; any `cheat` marks the segment reached; slot 1 is
  refused in the core AND the driver; `exec` needs a per-session token file.
- **Reuse.** The dev loader; the vendored LuaSocket (BizHawk's, and UE4SS's proven copy);
  `cmd_drive.lua`'s measured functions as the first BizHawk driver's game modules; the shots folders;
  the handoff table; TEVI's ScriptEngine and the dev-cheats plugin pattern; Pseudoregalia's
  `probe_reloader`; fakeadapter, netsim and `-loopback` for scenarios that need a peer; the
  `play-game` skill as the manual; the `result` line's `num_turns` for the session loop.
- **A change to the order**: the scenario runner straight after Phase 1, since it is the part that
  pays off with no model at all.
- **Risks.** Globals shared with the adapter under the dev loader, and a driver confounding any cost
  measurement; an input driver left loaded; port collisions; PC "snapshots" and autosaves carrying
  cheats into real saves (TEVI's crystals are save data); tier-0 OS input reaching whatever window
  has focus; MCP discovery; the SDK's licence and dependencies; unattended launches;
  knowledge files drifting from adapter docs; `cmd_drive` being vanilla-only.
- **Questions put to the user**: may the loop start and close emulators on its own; how PC games get
  a snapshot, if at all; JSON scenarios (no dependency) or YAML; the reorder; adopting the MCP Go SDK
  once `licensing.md` has its row.

## 2026-09-16 (later) — the checkpoint answered

- **Starting and closing games.** The user: *"yes its fine to start/close emulators and games on its
  own. but similar to scaffolding it should be something i have asked for or something needed for
  current testing/work. can be assumed to be fine if an agent is started for testing a game"*. So the
  harness and its agents launch and close emulators and games themselves when the work was asked for
  or the current test needs it, and closing what they started stays part of the job.
- **Snapshots on a PC game**: in-game save slots the user rarely uses, the way BizHawk keeps slot 1
  for the user (the user's suggestion, *"i think that might be fine"*). Before relying on it, measure
  per game where its saves live, how many slots it has, and which slot an autosave writes; back up the
  save folder before a session either way. Nothing about any game's save layout is measured yet.
- **Scenario and knowledge files are JSON.** The user left it to what is easiest to work with: Go reads it
  with the standard library, so no dependency or licence row; everything else here (the bridge,
  `config.json`, recordings) is already JSON; and it has one way to write a value. YAML's advantage,
  comments, is covered by a `note` field.
- **The order changes**: the scenario runner comes straight after Phase 1 (*"If you think that makes
  more sense go for it"*).
- **MCP** was asked about rather than answered — what it is for — so the Go SDK is not adopted yet.
