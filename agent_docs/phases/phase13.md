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

## 2026-09-16 (same session, later still) — Phase 1 step 10: both bikes, and a Mach Bike that still stops on its tile

**The user, on the bikes:** *"the acro bike is a bit slower, but think its still faster than running"*,
*"the mach bike has acceleration and different speeds, and is hard to control properly even for a player
while at full speeds"*, *"faster movement is prefered, as long as it don't decrease precision"*, and the
aim: *"the optimal endgoal would be if you could use mach bike at full speed to navigate everywhere
without hitting any obstacles at all, that would be better than how a player normally does it"*.

**Built.** A `register_item` cheat (the SELECT item; the write `cmd_drive.lua` measured), `movement` in
`observe` (on foot, Mach Bike, Acro Bike), and `walk` on either bike: the Acro Bike stops where released,
so it rides like walking; on the Mach Bike `walk` lets go as soon as holding one more tile would coast
past the target, and walks any shortfall. Measurements: `emerald/MEASURED.md`, same date.

**How it was measured.** `probes/bike_probe.lua` logged the avatar block's first 16 bytes beside every
step. Per tile: walking 16 frames, running 8, the Acro Bike 6, the Mach Bike 16, 8, then 4. The Mach
Bike's +0x0B read 0, 1, 3 while held and counted down once released, one tile per unit — the rule `walk`
releases by. Live: Acro right 5 and left 3, Mach 1, 2, 4, 6 and 11 tiles, every one on its tile; the 11
in 87 frames stopping beside a wall with no bump in the log.

**What went wrong on the way:** the first Mach Bike release, done by hand with `press`, carried a tile past
where it was let go — the reason for the measurement, not a fault — and a first reading of +0x0B came
from the wrong byte of the hex dump until the bytes were indexed one by one.

**Toward the user's aim.** Straight legs at full speed without a bump now work; a route that turns needs
the bike's turning measured and a planner over `local_map`'s collision grid (the plan's `goto`, Phase 2).

**Next:** measure turning on the Mach Bike; then a `goto` that plans legs over the grid and rides them.

## 2026-09-16 (same session, later still) — Phase 1 step 11: `goto`, and battles and text as one call that stops when stuck

**Built.** `goto {x, y}` plans a route over the map's own grid (collision, elevation, characters, warps,
ledges closed; tall grass costed unless `cross_grass`) as straight legs, rides them turning at speed —
on the Mach Bike letting go early only for the last stop — and replans when a step is refused.
`battle {policy}` plays a battle to its end in one call and `advance_text` presses through a
conversation; both keep a `log`, press only when a measured state asks, nudge after 3 seconds of no
change, retry a press the game ignored, and answer `stuck` with what they were waiting on after three.
The driver lets a program name its own frame limit. Measurements: `emerald/MEASURED.md`, same date.

**The user, while it was built:** on routes, *"the optimal endgoal would be if you could use mach bike at
full speed to navigate everywhere without hitting any obstacles at all"*; *"you can use repel's to avoid
wild pokemon battles if you have any"*, *"if you have repel, its fine to cross grass/water. assuming the
pokemon in your first slot ... is higher level than the wild pokemons you won't get any encounters"*,
and *"some paths might require you to go across grass, with no way around"* — so grass is a cost, not a
wall. When a hand-made turn ran into a trainer: *"you hit the npc"*. Then, of the scratch battle loop,
*"seems like you get stuck at loops"*, then agreeing with the fix *"so i don't sit around waiting for several minutes for you to do something"*.

**Why the loop was slow and stuck.** Every step was a fresh `mcpcall` (a core start and a driver
reconnect, about a second), then fixed 60-90 frame waits, and it ran out a 120-step budget in silence
on a state it did not handle: RUN searched for on the move menu ~118 times, and a trainer's `finished`
box it had stopped pressing. The programs replaced it: the nurse's three boxes to her YES/NO in 10
seconds, a whole wild battle in 41 (the battle's own length at 60 frames a second).

**What went wrong on the way:**
- **The hand-made turn hit the NPC**: two `press` calls left the direction released for two frames, the
  bike coasted a tile further, and the turn landed in the defeated trainer's column. `goto` plans around
  characters and switches direction on the tile, with no gap.
- **A route crossed tall grass** into a wild WURMPLE, and another walked up a trainer's line of sight:
  grass now costs extra; sight lines are not known yet.
- **`advance_text` gave up on the nurse too soon**: her "for a few seconds" ignores A through its jingle;
  an ignored press is now retried. It also called a conversation closed after half a second (now 1.5).
- **A box still printing looked like no change**: the printer's pointer is now part of the signature.
- **Reloading the driver forgets text already on screen**, since text is learned as it prints.

**Next:** a trainer's line of sight for `goto`; a Repel from the bag (list menus); then Phase 1's
acceptance from a new game.

## 2026-09-16 (end of the session) — where Phase 1 stands, for the next chat

The user ended the session to continue in a new chat. The emulator this session started was closed and
checked gone, with nothing listening on 7870 and the autoplay loader target at `none`. The game was
saved first as the snapshot `session_end_route016` (gitignored `autoplay/states/emerald/`): route 0.16,
MUDKIP Lv8 at 15/26, two trainers on route 0.17 beaten. `pb_base` is the earlier town state. Nothing is
pushed.

**To pick up:** launch vanilla Emerald with `MESHGHOST_DEV_LOADER_TARGET=bizhawk-dev-loader-autoplay.target`,
`AUTOPLAY_GAME=emerald`, and the driver's path in that control file (the README's "Drivers so far");
`restore` a snapshot, then drive with the tools (`go run ./cmd/mcpcall` from `autoplay/`, or a session
with `--mcp-config autoplay/.mcp.json`). Prefer the one-call programs (`goto`, `battle`,
`advance_text`) over loops driven from outside.

**Next:** a trainer's line of sight in `goto`; the bag's list menu (a Repel, items in battle); then Phase
1's acceptance from a new game to the first trainer battle.

## 2026-09-17 — Phase 1 step 12: a trainer's sight in `goto`, `spotted`, and the level-up box

**Built.** `nearby` names a trainer: `range`, `sees` (every way it turns), `beaten` and its flag, and a
character's `facing`. `local_map` marks with `!` every tile an unbeaten trainer looks at, loaded or not
(a trainer out of view is read from the map's templates). `goto` costs those tiles far above grass, so a
route enters a line only where there is no other way, and `route_in_sight` names each one it had to.
`walk` and `goto` stop with `spotted` (the trainer's local id and distance) on the frame the step into a
line begins, instead of holding into a frozen player until `no_response`. `battle` waits while a trainer
walks over and turns both pages of the level-up box. Measurements: `emerald/MEASURED.md`, "A trainer's
sight and defeat flag, a trainer coming for the player, and the level-up box" (2026-09-17).

**How it was measured.** A snapshot on route 0.17 with two trainers unbeaten, restored before every
trial. RICK (range 2, facing up): three tiles above him nothing; two tiles above, he came. TIANA (range 3,
turning between down and right): four tiles right nothing, three tiles right she came -- but only once
she turned that way, with the player already standing there, which is why `sees` is every way a trainer
turns and not the way it faces when the route is planned. The defeat flag read clear before each battle
and set after. The new `probes/trainer_approach_probe.lua` found the byte that says a trainer is coming,
and the script context status that says a script is still running; `battle_state_probe.lua` gained the
battle script pointer and the struct that holds the level-up box's state.

**What went wrong on the way:**
- **`battle` quit at the level-up box**, `stuck` after two A presses that both worked: the box's state
  was in nothing the program watched, and it judged a press unanswered after 30 frames when the next
  message took 156. Both fixed: the box's state and the battle script pointer are progress, and `stuck`
  now also needs 180 frames of no change.
- **`goto` walked into TIANA's line and answered `no_response`**, as a route did on 2026-09-16: a trainer's
  approach freezes the player, and held input looked ignored. Now `spotted`.
- **`battle` called straight after `spotted` answered `no_battle`** after 90 frames, while RICK was still
  walking over. It now waits while the script context status says a script runs.
- **A trainer's defeat words sat in printer state 1** until a nudge; state 1 at FC 09 is now a message
  waiting for a button, and FC 09 and FC 0A decode as commands instead of letters.

**The user, while it ran:** asked how far along autoplay is, whether Crystal could be worked on at the same
time, and how similar games would share what autoplay learns; then whether an agent or a second chat
should take Crystal. A second chat, since Crystal will need launches approved and questions answered that
an agent cannot put to the user: *"okay i posted that into the other chat"*. For two instances, the driver
now logs to `driver_bizhawk_<game>_<port>.log` off the default port and `mcpcall` takes `-log`; the Crystal
chat runs on port 7871 with its own loader target. The route planner and text machine stay in `emerald.lua`
until Crystal needs them, so the two chats do not refactor them at once.

**Next for Phase 1:** the bag's list menu (a Repel, items in battle); then the acceptance run from a new
game to the first trainer battle.

## 2026-09-17 (later) — Phase 1 step 13: the bag's list, its item menu, and a Repel used through them

**Built.** `menu` now reads a scrolling list menu (every entry, scrolled off or not, with `list: true` and
in the bag the open `pocket`) and a grid menu such as the bag's USE/GIVE/TOSS/CANCEL (with `columns`), so
`select` works in both: it scrolled eleven rows to CLOSE BAG and reached USE across the grid. A Repel went
from the START menu to BAG, REPEL, USE and "A used the REPEL." with `select` and `advance_text` only; the
bag's count read 5 before and 4 after. Measurements: `emerald/MEASURED.md`, "The bag's item list, its item
menu, and a Repel used through them" (2026-09-17).

**How it was measured.** The decomp said the bag's list goes through the game's generic list menu, whose
state sits in a task's data; the new `probes/list_menu_probe.lua` logged every active task's routine, that
task's data and entries, the bag's position struct and the plain menu struct on every change, against
captures of the bag opened, a Down, a pocket switch and a list scrolled past the eight rows it shows. The
item menu's cursor moves through a grid routine the existing menu hook never saw, so two more hooks went in
(execute hooks cost the same however many there are).

**What went wrong on the way:** the START menu, opened again after the item menu, read as a two-column grid
with blank entries: a list menu's setup leaves the last grid's column count in the menu struct. A grid is now
told apart by which cursor routine last ran.

**Next for Phase 1:** the acceptance run, from a new game to the first trainer battle. The bag inside a
battle and the party menu an item asks for are not measured yet.

## 2026-09-17 (the Crystal chat) — Crystal step 1: position, mode, `walk`, text and menus, with no core change

**Built.** `autoplay/drivers/bizhawk/games/crystal.lua`, so the same core drives vanilla Crystal V1.0 on its
own instance (port 7871, its own loader target, beside the Emerald chat's on 7870): `observe` with `location`
(map, tile, facing), `mode` (`overworld` or `not_overworld`), `warps`, `dialogue`, `menu` and `screen_text`;
`walk` on foot; `select`. The core needed no change. One shared change: `select` in `driver.lua` waits for
the game to see a release where the module can say so (`game.inputReleased`); Emerald's module does not, so
its path is unchanged. Measurements: `crystal/MEASURED.md`, six entries dated today; tools: the README.

**How it was measured, the decomp as the map only.** Our V1.0 build's `.gbc` hashes identical to the ROM, so
its `.sym` said where to look. Three new probes: `autoplay_state_probe.lua` (read-only, ~50 state bytes and
the player object on change) through a cold boot, walks each way, a bump, a sign, the START menu, the PACK,
the POKéGEAR and a door each way; `autoplay_text_probe.lua` (read-only, the tile buffer and the menu block on
change) through the sign's boxes and SAVE's YES/NO; `autoplay_charset_probe.lua`, which wrote 0x60-0xFF into
an open message box so the game drew every byte, cut into a labelled sheet and named, then checked against
every word of real text read. Crystal's text is its tile buffer, so it needs no execute hooks — the thing
that halves Emerald's top speed.

**What went wrong on the way:**
- **`select` moved the START menu's cursor once and then never again.** The probe showed the game's own
  button byte still reading Down across the driver's 2-frame release: the menu looks at the buttons every few
  frames, missed the release, and a held button is not a new press. Waiting for that byte to read 0 fixed it.
- **A walk out of a house answered on the door tile**: the game walks the player off the outside door 2
  frames after the map runs, with the player at rest for those 2. `walk` now wants 8 frames of rest.
- **The core stopped building mid-session**: `runlog.go` was half-edited by the Emerald chat in the shared
  tree. This chat built its core and `mcpcall` from the last commit into its scratch folder instead of
  touching the file.
- **The first probe line listed no WRAM domain**: BizHawk's domain list is indexed from 0 and
  `table.concat` starts at 1. The reads themselves were fine.

**The user:** chose vanilla V1.0 for the launch. No in-game save was made; SAVE's YES/NO was reached with
`select` stopping on NO and left with B. Named snapshots in the gitignored `autoplay/states/crystal/`:
`main_menu`, `newbark_start`, `sign_text` (the town sign's first box), `start_menu`, `house_24_9_mat`.

**What Crystal needs next, and what waits for one chat:** a battle for `mode` (the save has no Pokémon: the
starter from the lab first), then `local_map` and `nearby`. `advance_text` and `battle` would reuse
`emerald.lua`'s text machine, which stays there until the user decides the move to shared Lua, in one chat.

## 2026-09-17 (later still) — Phase 1 acceptance: a new game to the first trainer battle, walked, one run log

**Result.** From a snapshot taken as Birch's speech began, the tools reached MAY's battle on Route 103 with no
input from the user, and won it. The run log (`autoplay/runs/2026-09-17_003014.570637.ndjson`, gitignored)
records segment 2 "load the new-game state" as **reached** (the restore) and segment 3 "new game to the first
trainer battle, tools only" as **walked**, closed the moment the battle began, across 630 calls and 58 cores.
On the way: the intro and naming, the truck, Mom, the clock, the TV, MAY's house, Route 101's rescue with
MUDKIP chosen, Birch's lab, Routes 101 and 103 with four wild battles, Oldale Town. Measurements:
`emerald/MEASURED.md`, "A new game to the first trainer battle" (2026-09-17). **CHECKPOINT** (the plan's end of
Phase 1): reported to the user before Phase 2.

**Presses outside the tools**, all on screens `observe` does not read: the main menu (Down, A), the naming
keyboard (A, START, A; later B, B, START, A to undo a nickname), the clock (A), the starter bag (Right, A),
and an A to face an object or start a conversation.

**Built on the way, each from a failure in the run:**
- **Run logs resume** (`runlog.Resume`, core and `mcpcall` `-resume`, two tests): each `mcpcall` started a
  fresh core with its own log, which would have split one run into dozens of files each opening a walked
  segment.
- **A message under way is recovered** from the text printer after a restore: Birch's speech read as nothing.
- **`advance_text` taps A and waits 20 frames on a message without an arrow**: an A held into the menu that came
  up answered the gender menu and "So it's A?" with their first entries.
- **`goto` enters warps and treats elevation 0 as open**: the house's stairs and mats planned as not open, and
  a first try at "enter from a neighbour" walked straight across the mats. Stairs, mats, the truck's door and
  town doors each measured as they came.
- **Nudges only in a battle or on a readable message**: a nudge picked TORCHIC on the starter bag, answered YES
  to a nickname and typed "AA". **`battle` stops `menu_open`** outside the battle, **waits while a script
  runs**, and leaves the ending to its quiet count in the overworld: MAY's walk away outlasted 3 seconds, and
  a first fix still pre-empted `ended` by 31 frames, found with `trainer_approach_probe.lua`.

**The user, while it ran:** before NEW GAME, *"if you press "new game" you will have to to pick a gender, a name
and a lot of other things. lot of text as well"*; later, *"keep going ur doing great!, i will tell you if i want
us to stop or take a break"*. The other chat started Crystal V1.0 and committed its first step alongside.

**Left open:** a battle message after STRING SHOT waits in a state `battle` does not count as waiting (a
3-second nudge each time); the naming keyboard, clock and starter bag have no reader; the plan's Phase 1 list
also named `exec` and a noclip cheat, neither built.

**Next:** the scenario runner, which the Phase 0 checkpoint moved to straight after Phase 1 (the plan's Phase 4:
a scenario that replays a measurement with no model, 3 of 3, and fails when its expectation is broken).

## 2026-09-17 (end of the session) — where autoplay stands, for the next chat

The user moved to a new chat as context grew. The Emerald emulator this session started (vanilla, port 7870)
was saved as the snapshot `session_end_route103` (Route 103 after MAY's battle, MUDKIP Lv7, money 3300),
taken off the loader (target `none`), closed and checked gone. The Crystal chat's emulator was left running.
Nothing is pushed. This session's lessons are filed (`pitfalls/by-lesson.md`, three 2026-09-17 entries; the
play-game skill's "tap confirm" line).

**Snapshots** (gitignored `autoplay/states/emerald/`): `new_game` (Birch's first box), `acc_met_may`,
`acc_got_mudkip`, `acc_before_may` (below MAY on Route 103, before her battle), `session_end_route103`;
`sight_armed_0_17` (route 0.17, RICK and TIANA unbeaten, on the old save); `before_new_game` (the old save on
0.17, before the soft reset). The acceptance run log: `autoplay/runs/2026-09-17_003014.570637.ndjson`.

**To pick up:** launch vanilla Emerald with `MESHGHOST_DEV_LOADER_TARGET=bizhawk-dev-loader-autoplay.target`
and `AUTOPLAY_GAME=emerald`, the driver's path in that control file, `restore` a snapshot, and drive with
`mcpcall` (built once, `-core`, and `-resume` for a run that must stay one record: README "Running it").
Prefer the one-call programs; on a screen `observe` does not read, look with `screenshot` before any press.

**Next:** the scenario runner (Phase 0's checkpoint put it straight after Phase 1). Open on Emerald: the battle
message after STRING SHOT that waits without being counted as waiting; readers for the naming keyboard, the
clock and the starter bag; `exec` and noclip.

## 2026-09-17 (the Crystal chat, later) — Crystal step 2: the map, characters, scripts, a picture, and a wild battle

**The user, on being told step 1 was done:** *"Keep going, il tell you if i want us to stop or take a break"*;
later, *"can we pause after you are done with what you are currently doing, and then continue in a new chat
after you have written down things you have learned from this chat ? context is getting high"*.

**Built on `crystal.lua`.** `local_map` and `nearby` (the collision formula `cmd_drive.lua` measured, now
checked on three maps, and the object records); signs in the map; `walk` names a character that refuses a
step, crosses a map edge, and stops with `script_started` the moment a script takes the controls; `mode`
says `battle`; menus read as grids and in a battle (the action grid and the move list, `select` RUN in 2
steps); `screen_text` and 0x60-0x7F only while the tiles hold a measured font. Measurements:
`crystal/MEASURED.md`, four entries (the map, a script taking over, which font is loaded, a wild battle);
two new probes (`autoplay_map_probe.lua`, `autoplay_font_probe.lua`); a new way to measure in
`_template/probes.md` ("A tile id is a letter only while the font is in that tile").

**Walked, not reached, up to the battle.** From the town: the west exit's scene with no Pokémon, into Elm's lab,
his whole speech (about 70 boxes read by the reader, YES/NO through `select`), CYNDAQUIL taken, the aide's
POTION, out, across the edge onto Route 29, into tall grass, a wild PIDGEY, RUN. The speech went through a
scratch stand-in for `advance_text` (a Python loop in the chat's scratch folder, untracked: A only on a
waiting box, stop at a menu or after 3 unchanged looks), because the real program waits on moving the text
machine to shared Lua. No in-game save; snapshots in `autoplay/states/crystal/`: `west_exit_approach`,
`lab_pick_one`, `lab_cyndaquil_picture`, `lab_take_cyndaquil`, `lab_has_cyndaquil`,
`newbark_with_cyndaquil`, `route29_east`, `battle_pidgey_appeared`, `battle_menu` (the move menu),
`route29_after_run` (CYNDAQUIL L5, one POTION, beside Route 29's grass).

**What went wrong on the way:**
- **An extra A with no box open started a conversation** with the girl the player faced. A press to advance
  text must look first; the scratch loop does.
- **A Pokémon's picture read as text** ("AHOV:dk"): it is drawn with the letters' tile ids. And in a battle
  the ids 0x60-0x7F draw HP-bar pieces, so the level mark read as a kana. Checksums of the tiles in VRAM told
  every screen apart; each font set was charset-probed on its own.
- **`walk` sat 135 frames on a scripted tile** holding a direction the game ignored; `wScriptRunning` going
  to 255 is the signal, and `walk` stops on it now.
- **The battle's action grid read as a message** — it is drawn inside a frame shaped like the message box.
  A menu whose items sit inside the box is not a message.
- **The move menu opened no window** (`wWindowStackSize` 0), so the first reader missed it; in a battle a
  menu counts without one.
- **A batch ran on the wrong state**: the previous call had restored the town sign, not the battle.

**To pick up (Crystal):** the instance (EmuHawk on vanilla V1.0, port 7871) was left running with its loader
target at `none`; put `autoplay/drivers/bizhawk/driver.lua` back in
`dev-scripts/bizhawk-dev-loader-autoplay-crystal.target` and `restore` `route29_after_run`. Next, in order:
the battlers in memory (species, HP, moves, read against the battle screen) and a trainer battle (Route 30);
then the PACK's scrolling list. `advance_text` and `battle` for Crystal need the user's call on moving
`emerald.lua`'s text machine into shared Lua.

## 2026-09-17 (the Crystal chat, the same night) — the text-and-battle machine moved into shared Lua

**The user:** *"the emerald chat has stopped for now, and i will continue both of these chats in \"new chats\""*,
then of moving the text machine: *"do this now while this is the only active chat"*; and yes to launching vanilla
Emerald to check it.

**Done.** `drivers/bizhawk/text.lua` holds the machine and the `battle` and `advance_text` programs, moved from
`emerald.lua` with its comments; every read became a hook the module supplies (the list heads the file). The driver
calls each game module with the library (`local lib = ...`). Emerald's hooks are its old reads, and where it supplies
no optional hook the machine runs its old path. Crystal's hooks are this session's measurements, plus three the move
needed: a tap holds A until the game's button copy shows it (hJoyDown bit 0), a press waits for the release to be
seen, and a box is logged once printed (the screen fills letter by letter; Emerald's text is whole from its first
letter). Crystal's `battle` takes `run` only: its battlers and move data are not measured.

**Checked live.** Crystal: `advance_text` closed the town sign (221 frames), stopped `menu_open` at Elm's YES/NO (28),
waited out the POTION jingle (651), followed the west exit's scene while the girl walked the player back (688); `battle
run` ended the PIDGEY battle (480), and `strongest` is refused with the reason. Emerald (started for this, the Emerald
chat's snapshot `acc_before_may`): `advance_text` read MAY's five boxes to `battle_started`, and `battle strongest`
played her battle through FIGHT and TACKLE each turn to `ended` (`outcome_raw` 2 — MUDKIP lost and the player whited
out; in memory only, no in-game save).

**What went wrong on the way:** the first Crystal log listed every letter of a box as it printed; and the battle's
action menu, before its ▶ was drawn, read as a message with a frame column inside it — no message has a frame tile
inside, so that is now a condition of a message box.

**Left open:** both emulators (Crystal 7871, Emerald 7870) are running with their loader targets at `none`; closing
them is the user's.

## 2026-09-17 (the Emerald chat, new) — the scenario runner: RICK's sight replayed 3 of 3 with no model, and failing when broken

**The user, as it began:** *"Just keep going until i tell you to stop, i will be afk for a bit"*. The Emerald
instance the Crystal chat had started was still running, so this chat attached to it (the driver back in
`bizhawk-dev-loader-autoplay.target`) instead of launching one; its save was MAY's whiteout, at home.

**Built** (Go side; README "Scenarios"). `autoplay/scenario/` reads a JSON scenario -- `setup` and `steps`, each a
tool call with `expect` checks on its answer (a dotted path, `key[field=value]` to pick from a list, and
`equals`, `not_equals`, `one_of`, `exists`, `min`, `max`, `contains`) -- and runs it; `cmd/scenario` runs files
through the core's own server in its process over in-memory MCP transports, so a step is exactly an agent's tool
call and the run log labels each run's setup and steps as separate segments. It refuses before running anything: an
unknown field (a misspelled operator would check nothing and pass forever), a check with no operator, a tool the
server lacks, `restore` and `snapshot` (a scenario makes its state with cheats), and a driver on another game or
variant. The first scenario, `autoplay/games/emerald/scenarios/trainer_sight_range.json`, the layout Phase 0
proposed for tracked game files.

**Why that measurement.** The acceptance (the plan's Phase 4) asks for a real measurement replayed. RICK's range
(`emerald/MEASURED.md`, the 2026-09-17 sight entry) is the game's own check run by an ordinary step, and cheats
alone make its situation, so it needs no savestate: clear his defeat flag (0x767), warp to (25,12), three tiles
above him; wait 120 frames and see RICK at (25,15) with range 2, unbeaten, no script started (status 2) and no
message; walk down one and see `spotted`, local id 3, two tiles away. Done first by hand through `mcpcall`, which
answered exactly that, then written down.

**Checked.** Go: tests for every refusal, the paths, each operator, a pass, a broken expectation, a failed setup,
expected and unexpected refusals, another game, a lost link, and end to end a scripted driver behind the real
server with the run log's labels read back from its file; `go test -race -count=10 ./...` clean in the module. On
the game (vanilla, the new game's save, which RICK's measurement was not taken on): 3 of 3, about 2.3 s a run, and 3
of 3 again from a clean start (warped home, script status 2); the run log read setup `reached` (`cheat:set_flag`,
`cheat:warp`) and steps `walked` for each run. **Broken on purpose**, from copies in the scratch folder: `tiles_away`
3 failed all three runs under `-all` at steps 2 with "trainer.tiles_away: want 3, got 2", and exit 1; RICK's flag
SET (the check on `beaten` dropped, so only the game could catch it) failed at the walk with "outcome: want
\"spotted\", got \"done\"" -- a beaten trainer did not come, as CALVIN had not.

**What went wrong on the way:** both tests of a broken expectation replaced a string that was not in the scenario
(`"tiles_away"` sits inside `"trainer.tiles_away"`), so the "broken" copy was the passing one; the package test's
own did-it-apply check said so, and the command's test, which had none, passed for the wrong reason until it got one.

**Left as it is:** the Emerald instance is on route 0.17 at (25,13) with RICK coming (the last run), the driver on
its target. Not built: a `speed` setting, checks on a MeshGhost adapter's own log, waiting on an event.

**Next on Emerald:** the battle message after STRING SHOT that waits without counting as waiting; readers for the
naming keyboard, the clock and the starter bag; `exec` and noclip.

## 2026-09-17 (the Crystal chat, next session) — Crystal: the battlers in memory, and `battle strongest`

**The user:** *"Just keep going until i tell you to stop, i will be afk for a bit"*.

**Built on `crystal.lua`.** `observe` has `battle` while `mode` is `battle`: `asking` and both `battlers` (species, nickname,
level, HP, and each move's name, PP, the maximum PP drawn, type, power and `accuracy_raw`). `battle` takes `strongest`
(the hooks `strongestMove`, power times the accuracy byte over moves with PP, and `endedReport`: `outcome_raw`, `money`,
`party_count`, the first party slot). Measurements: `crystal/MEASURED.md`, "The battlers, their moves, and what a move's
power and accuracy bytes do". Two probes: `autoplay_battle_probe.lua` (read-only) and `autoplay_move_write_probe.lua`
(writes one byte of the move struct while armed). `text.lua` is unchanged: Emerald's path is as it was.

**How it was measured.** The battler blocks, the move and name tables in ROM and the party slot were read against the
battle screen (19/19, 34/35, :L5, TYPE/ NORMAL, the HP bars' green pixels counted), the POKéMON screen (10/19) and the
trainer card (₽3000, the ID). Crystal never draws a move's power or accuracy, so those two were measured by what they
do: one TACKLE replayed frame for frame from one snapshot, the struct's byte held at 0, 70 and 140 (no damage, 8, a
faint) and the other at 0 and 255 (a miss, a hit). Two control runs matched frame for frame first, which is what makes
a one-byte difference readable.

**What went wrong on the way:** `battle`'s log listed "            d!" and "used TACKLE!" as boxes. The text probe showed
the game clearing a battle's box over 2 frames, and the machine logging the frame between; the first fix (a box whose
rows changed since the last frame is `printing`) left "d!" in, because that clear came 11 frames after a ▼ and the ▼'s
blink memory answered `waiting_for_button` first. A changing box now skips that rule; the town sign still reads in 221
frames and the battle in 2168, as before.

**Snapshots** (gitignored `autoplay/states/crystal/`): `route29_after_win` (CYNDAQUIL 10/19 after the PIDGEY fainted).

## 2026-09-17 (the Emerald chat, later) — the STRING SHOT stall was an animation, not a wait for A

**What was open:** `battle` nudged after "used STRING SHOT!" in every wild battle of the acceptance run, recorded as a
message state it did not count as waiting.

**Measured** (`emerald/MEASURED.md`, "A move's animation holds a battle's next message"). The Emerald instance's save
had RICK's challenge up (the scenario's last run), so it was snapshotted (`rick_challenge`) and `battle` played it: his
WURMPLE used STRING SHOT on the second turn and the nudge came. `probes/battle_state_probe.lua` gained the bytes the
build names gAnimScriptActive and gPauseCounterBattle, the first two text printers and every pad change, and the
battle was replayed from a second snapshot (`rick_battle_start`): after each "used STRING SHOT!" the byte read 01 for
228 frames and 01 again for 75, and "SPEED fell!" began 431 frames after the first message. The nudge's A fell inside
the 228 and changed nothing.

**Fixed.** The shared machine (`text.lua`) takes an optional hook, `animationPlaying`: while it says true in a battle,
the frames count as change, up to the script wait's 600. Emerald's reads that byte. **Crystal's path is unchanged**: its
module supplies no `animationPlaying`, so the new branch never runs there (its other optional hooks, `inputReleased` and
`tapSeen`, and the absent `boxKnownWhilePrinting`, are untouched). Not run on the Crystal instance, which is that chat's.
A first version only held the nudge until the animation ended, and it fired on the next frame (one replay). Then three
replays: seven STRING SHOTs, no nudge, 431 frames message to message with no button pressed -- the no-press control
the first reading lacked, filed as a lesson (`pitfalls/by-lesson.md`; a line on `before-trusting-a-reading.md`).

**Seen, not fixed yet:** restored at `rick_challenge`, `battle` answered `stuck` after 601 frames with an empty log. The
challenge box there is finished (last box, no arrow, printer inactive), and only a message whose printer is still
active is recovered after a restore or a reload, so the box read as nothing while a script ran. A tap of A and a
snapshot inside the battle got past it. Next: recover a finished box.

**Left as it is:** the Emerald instance after RICK's third replay (won, MUDKIP Lv8), the driver and
`battle_state_probe.lua` on its target.

## 2026-09-17 (the Crystal chat, same session) — Crystal: a trainer's sight and battle, the warp cheat

**Built on `crystal.lua`.** A `warp` cheat (the writes `crystal/probes/goto_map.lua` makes). `walk` stops `spotted` with the
trainer's map object and distance on the frame a trainer sees the player. `battle` waits while the trainer walks over,
presses A on the level-up stats box (a `levelUpPage` hook) and on a battle's waits with no ▼, and its `battle` field has
`kind` and leaves out an opponent not yet sent out. `nearby` gives a trainer's `range`, `beaten` and `flag`; `local_map`
marks its line `!`. Measurements: `crystal/MEASURED.md`, "The warp cheat" and "A trainer battle". New probe:
`autoplay_trainer_probe.lua` (read-only). `text.lua` untouched by this chat: the Emerald chat's `animationPlaying` hook,
committed meanwhile, is one Crystal does not supply.

**How it was measured.** Warped to Route 30 below Bug Catcher Don and walked up a tile at a time: nothing at four tiles,
he came at three. Each fix was then replayed from `route30_don_4below` with the probes loaded, and the older snapshots
replayed after the last one (sign 221 frames, wild battle 2168 and 480, Elm's YES/NO 28, the west exit 688, as before).

**What went wrong on the way:**
- **`battle` answered `no_battle` between Don's words and his battle.** A trainer's script reads wScriptRunning 1, not the
  255 every earlier script read, and the battle began after a stretch with no text. The hook now counts anything but 0.
- **`walk` answered `not_at_rest`** when Don saw the player: it only stopped on 255. Now `spotted`, as on Emerald.
- **Two nudges**, on the level-up stats box and on "Argh! You're too strong!": both wait for A with no ▼. The text probe
  showed wTextDelayFrames counting 5 down to 1 and back for as long as either waited, and on no other screen of the
  battle without a ▼, so in a battle that return to 5 counts as waiting (the ▼ is still read first).
- **The opponent read as the last battle's PIDGEY** at the start of Don's battle: its block is not written until his
  first Pokémon is sent out, and wCurOTMon reads 255 until then.

**Snapshots** (gitignored `autoplay/states/crystal/`): `route30_warped`, `route30_don_4below`, `route30_don_battle_start`.

**Next for Crystal:** the PACK's scrolling list.

## 2026-09-17 (the Emerald chat, later still) — a finished message is taken up after a restore

**What was open:** the entry above's "seen, not fixed" -- restored at RICK's finished challenge box, `battle` read no
message and answered `stuck`.

**Measured** (`emerald/MEASURED.md`, "A finished message's printer and window, and a stale one"). A new read-only
`probes/printer_state_probe.lua` logged the printers and windows whole. A finished message leaves its printer inactive
with the pointer one past the string's FF, and its window PUT: the first and last cells on its background hold its own
base block's first and last tiles (194 and 1FF for the 27-by-4 message box). A closed box reads 0 there, including after
a battle while the printer still points past "A got ₽64 for winning!". The START menu's frame draws into window 0's top
row, so the driver's existing top-row test alone would have taken a stale printer for a box. Field and battle messages
began at their buffer's first byte (0x02021FC4 and 0x02022E2C); 197 bytes before the field buffer held no FF, so going
back to an FF, as ROM strings are, would have run past the start. The byte text_probe logs as MBOX turned out to follow
the printer, not the box.

**Built** (`emerald.lua` only). `recoverDialogue` takes up a window whose printer is inactive when the window is put,
and its string -- read from the buffer's start, or back to the FF in the ROM -- ends exactly at the pointer; an active
printer's string in one of those buffers is now read from the buffer's start too.

**Checked live** (driver only, the probe off): restored at `rick_challenge`, `observe` read the box `finished` and
`recovered`, and `battle` played from "Hahah! Our eyes met!" to `ended` with no nudge; after it, and with the START
menu open, no message read. Regression: the sight scenario 3 of 3; `acc_before_may`, a tap to MAY, `advance_text` read
her five boxes to `battle_started` and `battle` played her battle to `ended`, as on the Crystal chat's check.

**Left as it is:** the Emerald instance after MAY's battle, only the driver on its target.

## 2026-09-17 (the Crystal chat, same session) — Crystal: the PACK's item list, read whole, and `give_item`

**Built on `crystal.lua`.** The PACK's item pocket reads as one `menu` with every entry and CANCEL, their quantities,
the cursor into the whole list and the item's `description`, so `select` scrolls to any entry; the item menu under it
(USE / GIVE / TOSS / QUIT) reads as it did. A `give_item` cheat for items the game files in the item pocket.
Measurements: `crystal/MEASURED.md`, "The PACK". New probe: `autoplay_bag_probe.lua` (read-only). The driver's `select`
is unchanged.

**How it was measured.** The save had one POTION, so the game's own filing came first: Route 30's item ball, whose
message named the ITEM POCKET, and the attribute byte POTION and ANTIDOTE share. Then `give_item` filled the pocket to
9 entries, and Down pressed through all of them with the bag and text probes loaded: the scroll position, the cursor's
row and the list size give the entry under the ▶. Live: ICE HEAL, back to ANTIDOTE, CANCEL, then REPEL, USE, "A used
the REPEL.", and the list again with REPEL at 1.

**What went wrong on the way:**
- **`select` stopped after its first Down** with "the menu closed or changed": the game redraws the list after a move
  and draws the ▶ 5 frames later, so for those frames no menu reads. The reader keeps the whole list for 10 frames
  after it last saw it.
- **The item's description read as a finished message**, which `advance_text` would have pressed A on in the PACK. It
  is the menu's `description` now.
- **A name read from the tiles was cut** ("SUPER POTIO"): the list's rows are checked against the pocket's names as
  prefixes, and the names come from the game's table.
- The earlier snapshots replayed unchanged after this (the sign, Elm's question, the wild battle, Don's battle).

**Snapshots** (gitignored `autoplay/states/crystal/`): `route30_facing_antidote`, `route30_got_antidote`, `route30_items9`,
`pack_items_open`, `pack_items9_open`.

**Next for Crystal:** the three steps asked for are done. Open: `goto` (Crystal has only `walk`), the Pokémon menu and
the other pockets' lists, a trainer talked to or one that turns, what the save has in `observe`.

## 2026-09-17 (the Crystal chat, same session) — Crystal: a trainer talked to, through the same tools

Youngster Mikey on Route 30, walked up to from above and talked to with A: wScriptRunning reads 2 there (1 when a
trainer sees the player), and `battle strongest` played his words, battle and prize to `ended` with no nudge and no code
change, since the script hook already counts any value but 0. His defeat flag read 0 before and 1 after, a second
trainer's. Measurements: `crystal/MEASURED.md`, "A trainer talked to". Snapshot `route30_facing_mikey`.

## 2026-09-17 (the Emerald chat, later still) — the naming keyboard read, `type_text`, and the text speed on FAST

**Measured** (`emerald/MEASURED.md`, "The naming keyboard, and a blank box put back after it"). From `new_game`,
`advance_text` read Birch's 13 boxes to BOY/GIRL, `select` BOY, and `advance_text` stopped `stuck` on the keyboard
without pressing, as built. The new read-only `probes/naming_probe.lua` logged the naming screen's block while single
presses were made against captures: the name so far, the page (Select cycling capitals, small, symbols), a state byte
that says when presses are taken, the cursor's sprite holding its column and row, the template's length (7), and the
ROM's key table, whose three blocks matched the three pages drawn and every byte typed. **One press went further than
meant**: of six A presses meant as letters, the fifth made the name seven long, the cursor went to OK by itself, and
the sixth chose OK, so the name "H…TTTTT" was confirmed in memory; `ng_naming`, taken first, put it back. That became a rule of
the program.

**Built.** Emerald's `observe` gains `keyboard`; a new core tool `type_text {text, confirm}` (Go, with its validation
and forwarding tests); Emerald's program clears the name with B, then per character presses Select to the page,
single steps to the key and A, each waiting on the game's bytes and checking the typed byte, and presses nothing after
the last letter unless confirming. The shared machine takes an optional `readKeyboard` hook and `advance_text` stops
`keyboard_open` on it; **Crystal's path is unchanged** (no such hook in its module).

**Checked live.** "Ab1…" typed across all three pages in 279 frames, not confirmed, as drawn. "BRENDAN" typed and
confirmed in 366, and `advance_text` then read "So it's BRENDAN?" and stopped at its YES/NO. **Found on the way**: that
run's log began with "All right. What's your name?" -- after the keyboard, Birch's window 0 read put for 7 frames with
a stale printer while blank. `printer_state_probe.lua` gained each window's pixel buffer: one byte value in the blank
box, eight in RICK's finished one; a finished message now also needs something drawn, and the next run's log began at
"So it's BRENDAN?". Regressions after it: RICK's restored box still recovered; MAY's five boxes and battle; the sight
scenario 3 of 3.

**The user, while it ran:** *"can you go into options and change the text speed to be faster ?"*, then *"some rom hacks
have speed beyond 'fast'. but it should make all text dialouges go a bit faster than keeping it at 'mid' or 'slow'"*.
RICK's battle was played out first (his challenge was up from the scenario), then START, `select` OPTION, Right on
TEXT SPEED to FAST (a capture), B, and OPTION opened again read FAST. `advance_text` read RICK's words after it and
closed in 184 frames. Snapshot `fast_text_route102`; older snapshots keep MID. Also from the user, for later:
*"a pokemon is easier to catch if it has lower health, and if it has a status problem like paralazys"* -- `battle` has
no catching policy yet.

**Left as it is:** the Emerald instance on route 0.17 with FAST text, only the driver on its target.

## 2026-09-17 (the Crystal chat, same session) — Crystal: the ball pocket, a catch through the battle's PACK, two in the party

**Built on `crystal.lua`.** `give_item` and the PACK's whole-list reading cover the ball pocket; `ended` lists every party
slot; a box under a menu in a battle no longer reads as waiting for A. Measurements: `crystal/MEASURED.md`, "The ball
pocket, a POKé BALL thrown in a battle, and a second Pokémon in the party".

**How it went.** Route 31's item ball gave a POKé BALL and named the BALL POCKET; `give_item` made it six. In the grass Mom
called on the POKéGEAR ("Should I save it?", answered NO in this snapshot branch). A wild BELLSPROUT: PACK, POKé BALL,
USE through `select`; the first throw broke free, and replays from the USE / QUIT menu with different waits before USE
caught it on the fifth. The second party slot read against the POKéMON screen.

**What went wrong on the way:** under the ball's USE / QUIT in a battle the description box read `waiting_for_button`,
because the game counts wTextDelayFrames round under any waiting menu, and `battle` would have pressed A on USE; the
count no longer makes a box wait while a menu is on screen.

**The user, while it ran:** *"can you go into options and change the text speed to be faster ?"* — it already read FAST, the
fastest of the menu's three; BATTLE SCENE OFF and a memory write were offered, with no answer yet, so nothing changed.
*"a pokemon is easier to catch if it has lower health, and if it has a status problem like paralazys"* — the next catch
weakens first instead of replaying for luck. Then *"I stopped it as it looked like you got stuck, you never closed the
pause menu after going back out of the option menu"*: the game had sat on OPTION, then the START menu, for minutes while
this chat wrote records. The command stopped had already closed OPTION; the START menu was closed after. Filed as a
working rule for the agent (close menus before off-game work, and say the game is idle).

## 2026-09-17 (the Crystal chat, end of the session) — where Crystal's autoplay stands, for the next chat

**The user:** asked how far along the plan is (Phases 0, 1 and 4 done; 2 and 5 in part; 3 and 6-8 not started), then
*"okay we are still a bit away from tevi/pseudo then i guess. can we start a new chat and continue there ? context is
starting to fill up"*. On BATTLE SCENE: *"leave it, some attacks are faster/slower i think so probly good to have on for
testing ?"* — left ON. **Open with the user:** whether this chat's successor moves `emerald.lua`'s route planner into
shared Lua so Crystal gets `goto` (the Emerald chat had uncommitted work in `emerald.lua` at the time); not answered.

**Crystal now has** (vanilla V1.0, `crystal/MEASURED.md` for every reading): `observe` with position, mode, text, menus
(the PACK's item and ball pockets whole), `local_map` with trainers' lines, `nearby` with trainers' range and defeat
flag, both battlers, and party, bag and money; `walk` (`spotted`, `script_started`, `blocked`), `select`,
`advance_text`, `battle` (`strongest`, `run`; trainers seen or talked to, the level-up box, waits with no ▼), and the
`warp` and `give_item` cheats. Not yet: `goto`, scenarios, badges, party moves out of a battle, the key item and TM/HM
pockets, the Pokémon menu as a list, `movement` (bikes, surfing).

**Left as it is:** EmuHawk on vanilla Crystal V1.0 (port 7871) still running, the loader target
`dev-scripts/bizhawk-dev-loader-autoplay-crystal.target` at `none`; the Emerald chat's emulator also running. Snapshot
`session_end_route31` (Route 31 at (15,14) in the grass, CYNDAQUIL L5 10/19 and BELLSPROUT L5 20/20, 9 item entries, 5
POKé BALLs, money 3000, text speed FAST) beside this session's others in the gitignored `autoplay/states/crystal/`.
Nothing is pushed. The core and `mcpcall` this chat ran were built into its own scratch folder; a new chat builds its own.

## 2026-09-17 (the Emerald chat, end of the session) — the truck's door and the clock measured, memory moved into the repo, where to pick up

**The user:** asked which agent memories belong in the repo (`877e24a1`: the rig rules into `running-the-rig.md`, text
speed into the play-game skill, the rest checked against the repo and deleted where it already held them), then ended
this chat and the Crystal chat to start two new ones as context grew.

**Walked this session, from `ng_naming`:** "BRENDAN" typed and confirmed, Birch's speech to the truck, text speed FAST
set in the truck, out of the truck, Mom's words, upstairs, and the wall clock's screen. Measured on the way
(`emerald/MEASURED.md`, "The truck's door taken from rest, the wall clock's screen, and a question drawn instantly"):
- **The truck's door refuses a held step and takes one from rest.** `goto` now lets go one tile short of a warp entered
  by a press (the truck's door, a house mat) and takes the last step alone; from `ng_truck_fast` it entered in 73 frames.
- **The clock's hours and minutes are words in task 0's data** (the new read-only `probes/task_probe.lua`). The reader
  and a way to set a time are NOT built yet; `advance_text` still stops `stuck` there, without pressing.
- **An instant print leaves a window's printer as it was**: "Is this the correct time?" read as the stale "Better set it
  and start it!". The driver now skips a finished printer on a window whose last print was instant.

**Left as it is:** EmuHawk on vanilla Emerald (port 7870, started by the Crystal chat for its check) still running, the
loader target `dev-scripts/bizhawk-dev-loader-autoplay.target` at `none`, the game on RICK's restored challenge. Named
snapshots in the gitignored `autoplay/states/emerald/`, newest first: `ng_clock` (the clock screen), `ng_room`,
`ng_truck_fast` (FAST text), `ng_truck`, `ng_naming` (the keyboard, "H" typed, MID text), `ng_gender`,
`fast_text_route102` (the old save, route 0.17, FAST), `rick_battle_start`, `rick_challenge`, and the earlier ones
(`acc_before_may`, `new_game`, ...). Only `ng_truck_fast` and later, and `fast_text_route102`, carry FAST. Nothing is
pushed; once it is, read `gh run list -L 5` (this session changed `autoplay/` Go: the scenario runner, `type_text`).

**Next for Emerald:** the clock reader (measured) and the starter bag's reader, both on the new game's path from
`ng_clock`; then `exec` and noclip. Open with the user, from the Crystal chat's end: moving the route planner out of
`emerald.lua` into shared Lua so Crystal gets `goto`.

## 2026-09-17 (the Emerald chat, next session) — `goto`'s route planner moved into shared Lua, Emerald's answers unchanged

**The user, as it began:** the planner out of `emerald.lua` first, so Crystal can get `goto` by supplying hooks, with
Emerald's `goto` behaving exactly as before, checked live and committed; then the clock reader, the starter bag's reader,
`exec` and noclip. This answers the question left open at both chats' ends.

**Done.** `drivers/bizhawk/route.lua` holds the planner (Dijkstra over tile and facing: a step costs 1, a turn 2, grass 8
unless `cross_grass`, a trainer's line 100; the legs; `route_in_sight`) and `goto`'s ride (hold a leg, turn on the corner
tile, let go for a coast or before a warp taken from rest, plan again after a bump up to 8 times, hold into a warp), moved
with its comments. The driver hands it to every module as `lib.route`; a module offers `game.programs["goto"]` by calling
`lib.route.go(hooks, p)`. In `emerald.lua`, `walk`'s bump check and the Mach Bike's let-go rule became one function each,
shared by `walk` and the hooks.

**The hooks a game supplies** (the list heads `route.lua`):
- `position()` (map name and tile, the tile moving when a step begins) and `inOverworld()`;
- `watch()`, which makes the per-frame check for early stops (Emerald's: `spotted`, `dialogue_open`, `menu_open`);
- `atRest()`, `refused()` and `idle()`: the step states `walk` measured;
- `ride(run)`: buttons held with the direction (B to run), and for a ride that coasts, `coast(tiles)` and `shortLeg`
  (Emerald's Mach Bike, 3);
- `routeGrid(fromX, fromY, toX, toY)`: the map's size, a `where` for refusals, and `tile(x, y)` answering open, grass,
  and the trainer that looks at the tile;
- `warps()` and `enterWarp(w)`: stepped onto, a direction pressed on it (from rest or not), or a tile beside it;
- `blockedBy(x, y)`, and `limits` (rest, idle, press, door and step, in frames).

Crystal's `walk` already reads what most of these need. One thing the hooks do not cover: Crystal's `walk` waits after a
door until the game has walked the player off it (8 frames of rest on the new map), while `goto` answers `map_changed` on
the first frame the map differs, so a Crystal door would answer mid-warp until a hook for that is added.

**Checked live** (vanilla Emerald, port 7870, the instance left running): 24 calls made before the move and again after,
each from a restored snapshot, compared on outcome, reason, tile, tiles moved, turns, replans, frames, `entered` and
`route_in_sight` -- identical. The truck's door from `ng_truck_fast` (73 frames, as last session); Oldale's Pokémon Center
door from `town_start` and the lab's mat from `acc_got_mudkip`, walked and run; route 0.16 from `session_end_route016` on
foot (a turn, grass avoided and crossed, two routes into wild battles at the same frame both times) and on the Mach Bike
(three routes of 9 to 24 tiles with turns at speed); route 0.17 from `fast_text_route102` into trainer 2's line
(`spotted`, `route_in_sight`) and beside it; the player's own tile and three refusals (outside the map, a wall, RICK's
tile); five `walk` calls for the shared functions (a bump, a run, three Mach Bike rides). The sight scenario 3 of 3. Not
exercised live: a replan after a bump, and `no_response`. `goto` on Emerald can only answer through `lib.route` now, so
the second set ran the moved code.

**Crystal's path:** `crystal.lua` and `text.lua` untouched by this chat; Crystal's module never reads `lib.route`, and
the driver's one new load is `route.lua`, which loaded and ran on the Emerald instance and parses with `luac -p`. Not run
on the Crystal instance, which is that chat's.

## 2026-09-17 (the Crystal chat, new session) — Crystal: `set_flag`, a warp refused during any script, and the switch question

**The user, as it began:** continue Crystal beside the Emerald chat, which moves `goto`'s route planner into shared Lua
first; meanwhile a first Crystal scenario, the PACK's other pockets, the Pokémon menu, badges and movement. The chat
attached to the running instance (7871), restored `session_end_route31`, and built its core, `mcpcall` and `scenario`
from HEAD into its scratch folder.

**Built.** Crystal's `set_flag` cheat (the defeat-flag layout two trainers measured; ids 0-2047 from our build's `.sym`).
`warp` now refuses while wScriptRunning reads anything but 0. In `text.lua`, an optional hook `battleQuestion` and an
`answer` argument to the machine: a question inside a battle is answered where its kind is known and otherwise stops
`needs_choice`, never nudged. `battle`'s policies answer `switch` NO. Crystal reads the switch question and the nickname
question after a catch. **Emerald's path is unchanged by construction**: its module supplies no `battleQuestion`, so the
new branch never runs there; not run on the Emerald instance, which is that chat's. Measurements: `crystal/MEASURED.md`,
"A warp written while a trainer's script runs; the switch question and the nickname question in a battle".

**How it went.** Replaying Don's sight by hand for a scenario (flag cleared, warp four below, 120 frames, a step up:
`spotted`, map object 4, three tiles, as measured) left his script running, and a warp written then waited for his words
and his whole battle. That battle, played with `battle strongest`, met "Will A change POKéMON?" (BELLSPROUT is now in the
party): the nudge chose YES. **The user, watching:** *"you pressed "yes" for swapping a pokemon during a trainer fight
after defeating a pokemon ( there is a setting to change this in options, set/shift i think) so now you either have to
B/cancel/go back. or pick another pokemon"*; then *"the same thing can happen in emerald, not sure if its solved there
already ?"* -- it is not: Emerald's records list a switch as not seen, and its module would nudge there too; the hook is
there for that chat to supply. The program was stopped (only this chat's core and `mcpcall`, found by port, not the
Emerald chat's), `select` CANCEL went back into the battle, and it was played out. The question was then measured with the
text probe and the machine stopping on it, answered, and replayed with the probe off.

**Also asked, answered in chat:** *"does "battle strongest" account for move type advantage/disadvantage ? ... physical/
special moves, and pokemon have higher/lower physical/special attack & defense stats"* -- no: power times the accuracy
byte only, on both games. A policy that weighs matchups needs the type table and the stats measured first; queued for
Crystal after this session's list.

**Snapshots** (gitignored `autoplay/states/crystal/`): `route30_don_battle_start_2party`, `battle_don_party_menu_after_yes`,
`battle_don_switch_question`, `battle_nickname_question`.

## 2026-09-17 (the Emerald chat, same session) — the wall clock read and set: `observe`'s clock, `set_clock`, `clock_open`

**Measured** (`emerald/MEASURED.md`, "The wall clock set: PM, midnight, YES, and the clock viewed after"). From `ng_clock`
with `probes/task_probe.lua` beside the driver, held Right and Left against captures: the hours word runs 0 to 23 and the
period word turns 1 at 12 (PM drawn) and back at 0; the minutes move one a frame at full speed, and the frame a direction is
let go moves nothing more. The decomp, read as the map, named the task routines and said the AM/PM sign is on a turning
disk, which is why one capture 1 frame after 23:59 was set still drew AM and the next, 14 frames on, PM. YES was then chosen
for the first time: the game fades back to the room, MOM comes up and speaks, and A at the clock afterwards opens a view
screen whose task held 7:30, the time set, with 7:30 AM drawn.

**Built.** Emerald's `observe` gains `clock` (hours, minutes, period, `state`: setting, confirming, closing or viewing). A new
core tool `set_clock {hours, minutes, confirm}` (Go, with validation and forwarding tests; `go test -race -count=3` clean on
`server` and `cmd/scenario`) and Emerald's program: hold the shorter way round, let go on the frame the minutes read the
time, wait for the hands, then A, Up to YES and A. The shared machine takes an optional `readClock` hook and `advance_text`
stops `clock_open` on it; **Crystal's path is unchanged** (its module supplies no `readClock`). `emerald.lua`'s main chunk
reached Lua's 200-local ceiling on the way (`luac -p` refused it): the clock's constants are one table and `type_text`'s and
`set_clock`'s limits live inside their functions, which leaves the chunk at 198.

**Checked live.** `set_clock` to 10:00, 13:00, 9:59, 0:00, 23:59 and 12:01 without confirming, each in one held direction
with no overshoot and each capture drawing that time (after the sign had turned); 7:30 confirmed, then the view screen read
and drew 7:30. From `ng_room`: `goto` to the clock, a turn and A, `advance_text` read "The clock is stopped…" and "Better set
it and start it!" and stopped `clock_open` (123 frames); `set_clock` 10:00 confirmed in 33; `advance_text` read MOM's five
boxes to `closed`.

**Snapshot** (gitignored `autoplay/states/emerald/`): `ng_clock_set` (the room after MOM's words, the clock set to 7:30).

**Next for Emerald:** the starter bag's reader on Route 101, walking the new game on from `ng_clock_set`; then `exec` and
noclip.
