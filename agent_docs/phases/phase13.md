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

## 2026-09-16 (later still) — MCP adopted; Phase 1 step 1: the core answers, with no game yet

The user, on what MCP is for: *"basically "tools" that give you proper hands & eyes for playing a game
easier/better ? this sounds like a good approach"*, then *"Yee lets go ahead with this then"*, and on
growing it: tools can be added later, "more hands/fingers or an extra eye". Built, Go side only:

- **`licensing.md`** has the MCP Go SDK's row, written before any of its source was read.
- **`autoplay/`** is its own module (ADR 0071): `driver/` is the loopback hub one game driver connects
  to (a hello with capabilities and protected slots, request ids, a busy reject for a second driver,
  an event buffer, a 64 KiB line cap); `server/` is the MCP face (`status`, `observe`, `press`,
  `events`, each game tool refused when the driver did not announce it); `cmd/autoplay` runs both.
- **Checked with tools**: `go test -race -count=10 ./...` clean in both packages (the mingw64 gcc
  `run-gotests-race.bat` finds); a stdio smoke of the built binary (initialize, `tools/list`,
  `status`); and end to end, a headless Claude Code session given `--mcp-config autoplay/.mcp.json`
  listed the server as connected and called `status`, and the core logged its stop when the session
  ended, leaving no process and no listener on 7870.
- **`govulncheck`** on the module reports four standard-library findings in the local Go 1.26.5, each
  fixed in 1.26.6, and none in the SDK's code this module calls. CI installs the newest 1.26.
- **Also**: `.github/workflows/autoplay.yml`; preflight's root-binaries check skips `autoplay/`;
  `.gitignore` holds `autoplay/runs/` and `autoplay/states/`.

Next: the BizHawk driver, growing out of `cmd_drive.lua`, on vanilla Emerald.

## 2026-09-16 (later still) — Phase 1 step 2: a live driver in vanilla Emerald, from boot to walking

**Local Go now matches CI.** Asked about the 1.26.5 finding, the user: *"update it if its not what we
use on the public repo ? just leads to confusion if local vs public repo have version mismatching"*,
and then as a general rule, *"think its good to keep what is local and on the repo the same if
possible"* — now the first bullet of `environment.md`'s Host section. Go went to 1.26.8 (the official
MSI, checksum compared with go.dev's list); `run-gotests.bat` passed on it and the four root binaries
were rebuilt; `govulncheck` on `autoplay/` then found nothing the code calls.

**Built:** `autoplay/drivers/bizhawk/` — `driver.lua` (dev-loader script: LuaSocket from Emerald's
vendored copy, connect, hello, one request at a time, events for a map or mode change), `json.lua`,
and `games/emerald.lua` (only addresses `emerald/probes/cmd_drive.lua` already measured; facing and
action go out raw). The core gained `wait` and `screenshot` (the picture comes back as an image), and
`cmd/mcpcall` calls tools through a real stdio core without an agent.

**The live run** (one EmuHawk on vanilla Emerald, the driver as the loader's only target, no
MeshGhost adapter): from a cold boot, `press` and `screenshot` alone reached the overworld —
intro, title, main menu, CONTINUE, `mode` turning `overworld` with a `mode_changed` event — and a
16-frame Left press moved the player one tile (`x` 11 to 10, reported in `changed`). Two tools exist
because of what went wrong on the way, each the play-game skill's rule proving itself:
- **An A press on the title did nothing** and looked like a stuck menu; nothing explained it until a
  picture showed the title screen — the first Start had only skipped the intro. So `screenshot`.
- **A 60-frame B hold used as a wait backed out of the main menu** into the intro. So `wait`, which
  presses nothing, and its description says never to hold a button to wait.
- **`events` failed MCP's output validation on the first real event**: a `json.RawMessage` payload
  infers as an array of bytes. Fixed by decoding the payload; the regression test fails on the old
  type with the exact live error, and the module is race-clean at `-count=10`.

The screen also showed a second player beside the real one: the save keeping a ghost spawned in an
earlier dev session. The user: it goes away on leaving the area, and Emerald ships drawn ghosts now,
so it is not an issue.

## 2026-09-16 (later still) — Phase 1 step 3: snapshots, a warp, and a run log that labels walked or reached

**Snapshots are named files, never slots.** Before the first one, the vanilla Emerald state folder held
ten slot files, 0 to 9 — every slot already had a state in it, of the user's or a rig's. So `snapshot`
and `restore` use BizHawk's path form of `savestate.save`/`load` (its Lua function reference names the
path argument) into `autoplay/states/<game>/<label>.State`, which is gitignored. The core names the
file, the driver only saves or loads, and the core checks the file exists — and was rewritten, when
one was there — before answering. Slot 1, or any slot, is never touched.

**The run log** (`autoplay/runlog`, a file per session under `autoplay/runs/`) records every tool call
and labels each segment walked or reached; a segment becomes reached when a cheat or a restore
succeeds in it, never on a failure or a refusal. `cheat` checks the kind against the driver's
announced `cheat:<kind>`; Emerald has `warp`, the writes `cmd_drive.lua` measured.

**Live, one run:** segment "walk one tile" — a 16-frame Left press moved `x` 10 to 9, closed
**walked**; "back by restore" — `restore` put `x` back to 10, closed **reached** by `restore`;
"warp two tiles right" — `cheat warp 0.10 12,16` landed on `x` 12 and answered `done` after 10 frames,
closed **reached** by `cheat:warp`. The run log file holds the same five segments. The snapshot was a
33,720-byte file. **The screenshot taken the moment the warp answered was black**: `done` fires when
gMain.callback2 is back on the overworld, while the screen is still fading in; a picture taken later
showed the player on the new tile, and the save's duplicate player gone, as a warp clears it. How
long the fade lasts is not measured, so the README says to wait, not for how long.

Go side: `go test -race -count=10 ./...` clean with the new tests (a cheat marks the segment reached,
a refused kind does not, a snapshot the driver did not write is an error, a restore of a missing
label is refused, a path in a label is refused).

## 2026-09-16 (end of the session) — where Phase 1 stands, and what comes next

The .NET SDK went to 10.0.401 to match `tevi.yml` (the user's local-matches-CI rule); the TEVI test
project passes on it. The emulator the session started was closed and checked gone, with the
autoplay loader target left at `none`. Nothing is pushed: once it is, read `gh run list -L 5` for the
new `autoplay.yml`.

**Phase 1, still to build** (the acceptance: from a new game to the first trainer battle with no
user input, every segment labelled): an ASCII map around the player; dialogue and menu state; party,
bag and badges; cheats for items and flags; `select`, and a move that ends on the game's own state.
**Text is the next piece**, and on method the user was explicit: *"we measure/build our own things,
but we can use decomps as info or a map still to know what to do. we just shouldn't keep anything
decomp wise in the repo as "our fact"."* So Emerald's character encoding is learned from the game —
text drawn on screen against the bytes behind it — with the decomp as the map of where to look.

**To pick up in a new chat:** start an instance with `autoplay/drivers/bizhawk/driver.lua` as the dev
loader's target and `AUTOPLAY_GAME=emerald` (the README's "Drivers so far"), then drive it with
`go run ./cmd/mcpcall` from `autoplay/`, or give a session `--mcp-config autoplay/.mcp.json`.

## 2026-09-16 (next session) — Phase 1 step 4: text, menus and `select`, measured from the game

**Built.** Emerald's `observe` gains `dialogue` (the box on screen, its index, and `printing`,
`waiting_for_button` or `finished`), `menu` (items and cursor) and `screen_text`; the driver turns
watched keys into `dialogue_changed` and `menu_changed` events; and a new `select` tool, generic in
the driver, walks the game's own cursor to a named entry and confirms. The text hooks install only
on the ROM whose hash they were measured on (`gameinfo.getromhash()`, the same SHA-1 as `sha1sum` and
our pokeemerald build). Measurements: `emerald/UNVERIFIED.md`, same date; tools: the README.

**How it was measured, the decomp as the map only.** The build's symbols said where the text
routines, the printer and menu blocks and the message buffer live. `probes/text_probe.lua` hooked the
routines and logged raw bytes per window while the agent opened the START menu and talked to a
Pokémon Center nurse, and screenshots of the same frames paired each byte with its glyph. Then
`probes/charset_probe.lua` overwrote one message's buffer with bytes 00-F7 between ▶ markers, so the
game's printer drew all of them, and a script split each line at the marker's pixel mask and labelled
every glyph before any was read. The method went into `_template/probes.md` ("Make the game draw
what you cannot name").

**What went wrong on the way:**
- **The first menu hook missed the YES/NO.** The START menu was found from a hook on the routine
  named InitMenu; the YES/NO sets the menu block through another path. The live run showed its items
  in `screen_text` but no `menu`; both paths call Menu_MoveCursor, and a hook there caught both.
- **The box index was off by one at the arrow**, caught before the first run: waiting on its arrow,
  the printer's pointer is already past the box's end byte, so that byte belongs to the box shown.
- **A 400% speed request hid the hooks' cost** (238 vs 239 frames/s, the setting's cap). With the
  frame limiter off: 344 with no hook, 245.6 with one, 242.0 with five, so `AUTOPLAY_TEXT=0` exists
  and trimming hooks does not.
- **An inline-heredoc Lua script lost its backslashes** and failed to load; rewritten with the Write
  tool (the known trap).

**The user, while it ran.** On text speed: it can be set faster or slower, and romhacks like
Speedchoice and Archipelago add faster, turbo or instant modes; *"how fast the text scroll/appear on
the screen"*. So `dialogue.state` comes from the printer's own bytes, never from time; this save's
speed only was measured, and instant modes are unmeasured. Watching the nurse's box fill with
accented letters: *"did you change what the text itself would be ?"* — yes, for that one
conversation only: the probe rewrote the scratch message buffer, nothing in the ROM or the save.
Its 13th A landed on her YES, so she healed the party; no in-game save was made.

**Go side:** `select` in the core with its tests (validation, index 0 reaching the driver, the
capability refusal); `go test -race -count=10 ./...` clean in the module. **Live:** the START menu
(3 steps down to OPTION, 5 up to POKéDEX, `exit` confirmed and closed) and the nurse's YES/NO (NO in
one step), every result matching its capture.

**Next for Phase 1:** the ASCII map around the player; party, bag and badges; cheats for items and
flags; list menus and battle text; a move that ends on the game's own state.

## 2026-09-16 (same session) — Phase 1 step 5: the local map and `walk`; and a third record, MEASURED.md

**The user on the `select` result:** *"im unsure if its always in the same position ?"*, then *"meant
more where you start, how much up/down you have to do"*. It is not fixed and `select` does not need
it to be: it reads where the cursor is (the START menu opened on POKéMON once and on BAG another time,
the game remembering) and presses until the game's cursor byte says it arrived.

**Built.** Emerald's `observe` gains `local_map` (15 by 11 characters with a legend), `nearby` (the
other characters) and `warps` (every warp and where it leads); the core gains `walk {direction,
tiles}`, run in the game module as a program the driver calls once a frame, each tile ending when the
game says the step is done. Programs became generic in the driver (`game.programs`), and `select`
reads only the menu each frame. Measurements: `emerald/MEASURED.md`, same date.

**How it was measured.** `probes/map_probe.lua` dumped the grid, behaviours, objects and the header's
event lists on every tile change, and `probes/step_probe.lua` the player's movement bytes on every
frame they changed, while the agent walked a tile, into a wall, a turn and a long hold. The first dump
already agreed with an earlier walk: the header lists a warp at (6,16) to map 2.2, the door the agent
had walked through in the text session. The local map then matched both captures tile for tile.

**What went wrong on the way:**
- **A door read as "no response" twice.** The first limit gave up after 20 frames; the door's step
  began on frame 20. Counting only idle frames fixed the turn-first case (the avatar's +2 reads 1
  while the door opens) and missed the facing-it case, where every byte stayed at rest for the 20
  frames of the door opening. What says a door is coming is the warp list: a press toward a listed
  warp now waits for the step or the map change.
- **Rows of "behaviour 0xB5" below the Center's room** were the grid's border, not the room: the grid
  is 15 wider and 14 taller than the map header's own size (map 0.10: 35 by 34 against 20 by 20).
  Border cells now read `:`.

**Live, through the tools:** up 3 done; left 2 refused at once, the refused tile reported as
collision 1; out of the Center and back in, each `map_changed`. Go side: the `walk` tool's
validation and forwarding tests, `go test ./...` clean.

**The records split (the user, while this ran).** *"i have to confirm visually if something
happens/work visually in a game. but i can't really confirm if bytes are correct or not"*, then
*"verified/unverified should just be non code related things that i can verify like 'Jump is not
working' or 'fly is working properly now' etc. I think a MEASURED.md makes sense for you to put all
these code related things in"*; *"remember to also add it to _template so all adapters get it"*.
Asked where a source's unmeasured claim goes, the user chose the bottom of MEASURED.md ("Not measured
yet"). Asked why UNVERIFIED.md has no index when VERIFIED.md does: a queue was meant to drain, and
they have not; each gets one in the migration, and MEASURED.md got its index from the start (*"these
files have the habit of growing pretty fast"*). Done: `_template/MEASURED.md` and one per adapter,
preflight's mandated set and an index check, and the rule in `CLAUDE.md`, `licensing.md`,
`orientation.md` and the probe skill. Today's text entry moved out of `emerald/UNVERIFIED.md`, which
keeps an on-screen READY item. Sorting the older entries is a `status.md` task for another chat (the
user's call).

**Next for Phase 1:** party, bag and badges; cheats for items and flags; list menus and battle text.

## 2026-09-16 (same session, later) — Phase 1 step 6: party, bag and badges; `give_item` and `set_flag`

**Built.** Emerald's `observe` gains `party` (species, nickname, level, HP, stats, EXP, held item,
moves with PP), `bag` (per pocket, in the bag's order), `money`, `badge_count` and `badges` — only
in an `observe` the agent asks for, since a press's `before` and `after` would carry them every time
(a `wait` answer stayed at 847 bytes). Two cheats: `give_item {item, quantity}`, by the name the bag
shows or an id, into the pocket the game's item table names, and `set_flag {flag, value}`; each
answers with a `report` read back from the game, which the driver now forwards for any cheat.
Measurements: `emerald/MEASURED.md`, same date; tools: the README.

**How it was measured, the decomp as the map only.** The build's symbols said where the party and the
name tables live and its structs where to look inside them. `probes/party_bag_probe.lua` dumped the
party, pockets, money and the badge-range flag bytes raw, with candidate decodes beside the raw
bytes, and the agent opened the party menu, three summary pages, all five pockets and the trainer
card to read each against the screen: a level-6 MUDKIP at 17/22, TACKLE 32 PP, EXP 221, ID No.
23633, RARE CANDY x99, ₽3300, eight badges.

**The one table, asked of the game.** A Pokémon's four encrypted blocks change order with its
personality, and one party shows one order. Rather than carry the decomp's switch,
`probes/substruct_order_probe.lua` hooked the routine that picks a block, at its entry and at its
return address, and rewrote the party as six copies re-keyed round by round to all 24 residues, with
all four blocks holding the same valid data so any order drew a real Pokémon. Paging the summary
answered all 96 residue/kind pairs with no conflict, and the answers follow a rule — residue r is the
r-th lexicographic ordering — so the driver generates them. The method is in `_template/probes.md`
("Ask the game's own routine for a table").

**The cheats measured themselves on the screen.** Three trainer cards, each drawn after clearing the
badge flags whose index had one bit set, gave every badge position a unique on/off code: flag
0x867 + i is badge i + 1. `give_item` put ORAN BERRY x3 under BERRIES (the pocket number no item on
this save had), POTION x2 under ITEMS and POKé BALL from 5 to 8, each drawn so; it refused a stack past
99, an unknown name, and any item with the trainer card open.

**What went wrong on the way:**
- **My own residue arithmetic was wrong**: done by hand, the MUDKIP's personality read as residue 14,
  which would have made the measured layout look inconsistent with an ordering rule; the probe's own
  `% 24` said 6, and residue 6 is exactly that layout. The instrument, not the head, does arithmetic.
- **Rounds 1-3 collected nothing at first**: the routine runs when a screen LOADS a Pokémon, not while
  one is shown, so a round written with the summary open needed each slot paged to again.
- **Two Bs left the summary but not the party menu** — the second landed in the summary's fade-out; a
  screenshot showed it, and a third B closed it.
- **The JSON encoder writes an empty table as `{}`**, so an empty pocket, a Pokémon with no moves or no
  badges would have read as objects; each is left out instead, with `badge_count` always present.

**Seen and not fixed:** pressing A on a Pokémon in the party menu, the press's `before` reported a
`menu` on window 1 with seven empty items — the START menu's window id, reused by the party menu, and
still counted open because the START menu was never removed through the hooked routine. A false
`menu_open` can stop a `walk` or mislead `select`; it is the next thing to measure, with list menus.

The session's snapshot `pb_base` (in the gitignored `autoplay/states/`) holds this save in the town.
The user asked whether the three untracked files in `agent_docs/plans/` are still needed. The two
play-game files are done: the skill and its references exist and `playing.md` is
`playing-rationale.md` (`phase12.md`). `autoplay-plan.md` is not: its corrections are in Phase 0 above,
but its Phases 2-8 and their acceptance checks exist nowhere else in the tree. Nothing was deleted.

**Next for Phase 1:** the stale menu window; list menus (the bag, the party menu) and battle text.

## 2026-09-16 (same session, later still) — Phase 1 step 7: a new screen's windows, and what the driver costs

**The stale menu window, measured and fixed.** `probes/window_life_probe.lua` logged every call to the
window routines while the agent went from the START menu into the party menu and back. Choosing
POKéMON never removed the START menu's window 1: the game freed all window buffers and ran the routine
the build names InitWindows, which rewrote the window table, and the party menu then drew into window
1 itself. The driver now forgets its windows' text and menu at InitWindows, and after a `restore` (a
loaded snapshot is not the memory the hooks saw). Live: no menu in the party menu, the submenu's three
items on window 8, `select` CANCEL, and the START menu read again on the way out.

**A sixth hook needed pricing, and the price on record was wrong.** `probes/hookcost_probe.lua` turns
the frame limiter off for a settled sample. Taken with NOTHING loaded first, it read 835 frames/s,
against the recorded "344 with no hook": that figure was the driver's reconnect loop, a 50 ms connect
attempt every 30 frames with no core listening. With a core connected, 818 with no hooks, 415.5 with
the six and 410.5 with one no-op hook: any hook halves top speed, and the count does not matter. The
driver now retries by the wall clock, once a second: 802.5 with no core and no hooks, 402.5 with the
hooks. The lesson is filed (`pitfalls/by-lesson.md`, a line on `before-trusting-a-reading.md`), and
`_template/probes.md`'s cost section now says to take the baseline with nothing loaded. Phase 0's
risk list had named it: "a driver confounding any cost measurement".

**What went wrong on the way:**
- **The first "connected, six hooks" run read 820, which would have meant hooks are free.** The
  `AUTOPLAY_TEXT="0"` global that a scratch script set for the no-hook run outlived that script's
  removal from the loader, so the driver installed none; its own log line said so, and a scratch
  script clearing the global went first in every later run.
- **The first existence check called `emu.limitframerate` absent**: BizHawk's functions are userdata
  here, so `type(f) == "function"` is false for all of them.
- **The first samples never settled**: the frame-rate reading climbs for several seconds after the
  limiter goes off (60 to 778 over ten samples), so the median is now of the last 20 of 30.

**Next for Phase 1:** list menus (the bag and the party menu's own cursors) and battle text; then the
acceptance run, from a new game to the first trainer battle.

## 2026-09-16 (same session, later still) — Phase 1 step 8: wild battles, and what a move does

**Built.** Emerald's `mode` reads `battle`; `observe` gains `battle` (what it is asking, and per
battler its side, species, level, HP and moves); in a battle `menu` is the action or move menu as a
two-column grid, and `select` reaches a grid entry's column first, so FIGHT, a move by name and RUN
are one call each. Every move in `party` and `battle` now carries its type, power and accuracy, and in
`party` its base PP and effect text. A `battle_input_changed` event says when the battle starts or
stops waiting. Measurements: `emerald/MEASURED.md`, same date; tools: the README.

**How it was measured.** A warp to a route's grass (found with `find_behaviour.py`), walks until an
encounter, and `probes/battle_state_probe.lua` logging the battle's globals, battler records and
message buffer on every change, read against a capture of each message, both menus and every cursor
position: HP 17 → 15 → 13 as drawn, PP 32 → 31 → 30, the level-up's 15/24, and the controller routine
that runs while each menu waits for input. The driver's existing text reading already showed every
battle message. Then three more battles by the tools alone: GROWL (Right), TACKLE (Left), MUD-SLAP
(Down) and RUN (Right, Down, "Got away safely!").

**The user, while it ran:** *"different attacks do different things, you can check what
type/power/effect they have in your "pokemon" bag"*, then *"both inside/outside of a battle, if you go
to your pokemon bag and look at a specific pokemon"*. It came as GROWL, picked only to exercise the
cursor, left the POOCHYENA's HP at 15/15, and a later TACKLE left it at 1/15. So
`probes/move_data_probe.lua` dumped the move table's entries for the MUDKIP's three moves, and the
summary's BATTLE MOVES page, each move selected, named the bytes: power, type, accuracy, PP and the
effect text, word for word. The page was read outside a battle; the in-battle route to it was not
opened.

**What went wrong on the way:**
- **Window text in a battle lied**: the action and move menus stayed in `screen_text` while "MUDKIP
  used TACKLE!" played, since their windows' bytes kept reading as drawn. It is left out in a battle,
  where `battle` and `menu` say what is asked.
- **The game's formatting commands printed as letters** ("FIGHT{FC}Û{38}BAG"). The captures showed
  four FC codes each taking one byte and drawing nothing (BAG exactly 0x38 px right of FIGHT, counted
  in pixels), so those read `{FC 13 38}`; the level-up's FC 0A and the escape message's prefix stay
  raw until measured.
- **A first version of the type-name read was wrong before it ran**: it read index + 1, written to
  get past the name reader's refusal of 0, which is NORMAL's index. Rewritten as its own read.

**Next for Phase 1:** a trainer battle (what its type flags read, the trainer's text), then the
acceptance run from a new game.

## 2026-09-16 (same session, later still) — Phase 1 step 9: walked to the first trainer battle; held movement and running

**The user, as this began:** the two finished play-game plan files were removed from
`agent_docs/plans/` (*"guess remove these 2 then ? and keep the 3rd one we still need for now"*);
`autoplay-plan.md` stays. Then *"there are some trainer fights if you go up to the town, and then to the
left"*.

**Walked there, not warped.** From route 0.16 up across the edge into the town and left across the next
edge onto route 0.17, each crossing a `map_changed`. `probes/find_objects.py` listed 0.17's character
templates with a nonzero trainer field; the one at (33,14), drawn facing down, ignored the player three
tiles to its right and walked up to them when they stepped into its column three tiles below, and
`walk` answered `dialogue_open`. The battle — YOUNGSTER CALVIN's POOCHYENA — was driven by the scratch
loop through `select` only, choosing each turn the usable move with the most power times accuracy
(TACKLE over MUD-SLAP, from this step's move data), and won: `money` 3300 to 3380. Measurements:
`emerald/MEASURED.md`, same date. **This is Phase 1's acceptance battle reached from a save in progress,
not from a new game.**

**Running, and holding the direction, from the user watching.** *"remember that you can also run by
holding B if you have the running shoes"*, then of the first `run`: *"looks really weird when you
run,stop,run,stop but i guess its to keep track of where you currently are ? can't you read where all
the objects/terrain/npc's are ? and know how to navigate around things"*, and on the reply's wording:
*"a player would mix walking/running/bikes during normal gameplay ... walk for full precision/before
unlocking run, running to go a bit faster but still precice, bike for long distances but might hit
walls~ ... this applies to other games as well"*; on bikes, *"the acro bike is a bit slower, but think
its still faster than running"* and *"the mach bike has acceleration and different speeds, and is hard
to control properly even for a player while at full speeds"*. So: `walk` gained `run` (the core's
input, with its test), and now holds the direction from the first tile to the last — `step_probe.lua`
showed a held chain arrives for one frame between tiles and a bump reads distinctly — and the choice
of movement went into the play-game skill's `references/navigation.md` and `playing-rationale.md`.
The per-tile stop had never been needed for position: the coordinates change the frame a step begins.

**What went wrong on the way:**
- **The scratch battle loop quit before the battle**: it treated `overworld` as the end, and a trainer's
  challenge plays in the overworld.
- **Its A presses on a "finished" message chose FIGHT** when the action menu came up under them; it went
  on to choose a move, so no harm, but a message press must not land on a menu.
- **Printer state 3** (the arrow before a scroll) was unmeasured and read raw; one capture named it.

**Next for Phase 1:** the bikes, measured as their own movement (the Acro Bike's speed, the Mach Bike's
acceleration and whether a held chain still stops on its tile); then a new game to the first trainer.
