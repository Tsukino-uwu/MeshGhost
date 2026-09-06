# Working notes for Claude

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

MeshGhost is an online multiplayer layer for singleplayer games: cosmetic ghosts by default, deeper
planes opt-in and unused. Read `agent_docs/brief.md` (the vision) and `agent_docs/contract.md` (the
implemented contract) before proposing a plan that touches the core, an adapter, or the relay.
`agent_docs/README.md` indexes every internal doc — start there; this file holds only rules.

## RULE 0 — THE 200-LINE CAP. Outranks every other rule in this file, without exception

**Before adding a line here, run `wc -l CLAUDE.md`. Over 200 is a regression and is reverted like
one.** The question is never "can I add this?" but "what comes out?", answered in the same edit; if
nothing can, the rule is not important enough to be here. The rule lives here, its reasoning in
`agent_docs/` behind a one-line pointer. Why: past ~150-200 instructions a model follows every rule
worse, and earlier ones better than later, so this file is ordered by what a violation costs. Capped
(each declares `<!-- line-cap: N -->`): this file, the four nested `CLAUDE.md`s, the two skills, and
the STACK a session loads (root + `adapters/` + host). Nothing else is; indexes and queues are held
to one line per entry instead. The cases: `agent_docs/claude-md-cap.md`.

## What never changes

- **The core never touches the game, and no config or feature may make it game-aware**: no game
  memory, no rendering primitives, no `if game == "emerald"` in `core` or `relay` (ADR 08-20).
- **Adapters never speak the relay protocol.** An adapter holds a socket to its own local core (the
  bridge) and nothing else: no relay address, no bytes off-machine (`agent_docs/contract.md`).
- **`area_id` and `anim` are opaque to the core**: compare by equality only; never a universal
  animation vocabulary or a branch on area contents in game-agnostic code.
- **Nothing that SHIPS writes a save, game state, or a ROM patch — ever, not even as a feature**, and
  it holds for every plane added later (world custody is the worst temptation). Dev-only test
  tooling may cheat: a probe, never an adapter (2026-08-18; `plans.md`; `_template/README.md`).

## Who verifies what

- **The user verifies the games; you verify the Go side. That split never moves.** `core`, `relay`,
  `transport`, `bridge` and `cmd/` are deterministic code against a contract we own: confirm them
  with tools yourself, never by asking the user to watch. An adapter is the opposite — **"it ran
  without errors" is not evidence**, because a wrong address returns a plausible number, so only
  the expected thing seen on screen in a running game settles it (`agent_docs/testing.md`, top).
- **A Go-side change is done when `dev-scripts/run-gotests.bat` is green**; `run-gotests-race.bat`
  when touching concurrency; `-count=10` has caught what 1 and 2 miss (2026-08-16); a behaviour change
  gets a regression test that fails without the fix. Fuzzing and cross-compiling are CI-only, so a
  green script is not a green CI (`agent_docs/testing.md`). **The netsim rig is always the worst case
  a shipped default must survive, and a rate/interp verdict is made on nothing milder** (`run-netsim.bat`,
  no-arg: NA↔EU ping plus bad wifi; user, 2026-09-02).
- **`VERIFIED.md` is append-only, and nothing adapter-side on the VANILLA game goes in it — or gets
  called "verified"/"confirmed" — until the USER confirms it on screen.** No probe log, console read
  or screenshot of yours substitutes (2026-08-21): your measurements go to that adapter's
  `UNVERIFIED.md`. A patched ROM (Archipelago etc.) and Go-side facts are yours to confirm — say so.
  Each adapter keeps its own record; `agent_docs/verified.md` keeps the Go side and the index.
- **THE BAR IS 1:1** — user, 2026-08-19: *"it looks exactly the same as the player doing it"*, *"not
  sloppy/bandage/good enough"*. Judged ON SCREEN, never by matching numbers: a state the game never
  displayed is not 1:1; "close" and "only during the transition" are OPEN. **Never offer a rate,
  tick or architecture change as the answer — that is an excuse for the defect.** Fix the cause;
  `BANDAGES.md` for real debt; read the game's own asset, never a lookalike.
- **Never assume what a game is MEANT to do — ASK.** A change to what the player SEES needs the
  user's confirmation of intent first; reasoning from the code turned TEVI's pause-menu ghosts into
  a false regression (2026-08-18). **Name the exact state: "main menu", never bare "menu".**
- **No addresses or APIs from memory.** Every offset, hook and third-party call traces to a file in
  a repo or a documentation page; anything suspiciously tidy is invented until confirmed against it.
- **If a game has a cleared decompilation, READ IT FIRST** (`licensing.md` clears the four `pret`
  decomps; `environment.md` has them built locally). Measurement CONFIRMS what the source says, it
  does not discover it, and a probe cannot tell you what a byte MEANS (2026-08-23; `pitfalls.md`).

## What may enter the repo

- **Nothing goes in that couldn't be published. The test is "fine in a public repo forever?", not
  "does a license permit it?"** No or unclear means out; a permissive license is not an exception.
  **Facts may be used and recorded with a citation; expression never** — decompiler output,
  disassembly, game binaries, assets, ROMs, symbol files, verbatim dumps, structurally identical
  code. It also filters which approaches to adopt, and clean isn't enough: **the repo must WORK for
  a user who has only it plus what they legitimately own** (`agent_docs/access-models.md`).
- **Read a project's license before reading its source** (`agent_docs/licensing.md`); not listed
  there means not checked, so don't use it. Learning a fact is normal; copying source or assets is
  not. **A private or invite-only source is a harder no: never named, linked, cited or derived from
  in any tracked file** — agent memory only, and what it touches stays independently measured.
- **No personal username, home path or machine-identifying detail in any tracked file — prose
  counts.** Genericize, cite outside files by filename only, suspect pasted tool output above all.
  `.githooks/pre-commit` refuses it (`git config core.hooksPath .githooks` once per clone, never
  `--no-verify` past it); CI and preflight re-scan the tree (`pitfalls.md`, four cases).
- **A dated fact in `agent_docs/` is true as of its date**: tools, mods, ROM patches and external
  repos drift without this repo changing, so re-check before a new use. **Cite dates, never
  durations, even for emphasis**: the repo was born 2026-08-11 (preflight fails the common ones).

## Working with the user

- **NEVER suggest stopping, pausing or resuming later — not even as one option among several** —
  and never invoke the clock, the session length or the attempt count. "It's late", "good place to
  stop", "pick it up fresh" and every variation are banned in prose AND as an `AskUserQuestion`
  choice: offering it is suggesting it (2026-08-17). **Silence means keep going until it works**;
  if blocked, name the blocker and the next measurement.
- **Commit freely, straight to `master`; never create a branch; push only when told to, in that
  message** — a past yes is not a standing one and "commit this" never implies it. **This overrides
  the harness default "if on the default branch, branch first"**, which produced the one violation
  (2026-08-16). A stray branch is `git merge --ff-only`'d onto `master` and deleted.
- **Ask before touching anything outside `C:\dev\MeshGhost`.** **Small runnable steps only**, each
  with a visible outcome ("echo to self", "see on second client").
- **You run the scaffolding for a live test; the user only opens and closes the game.** Start the
  relay, the core and any `dev-scripts` launcher yourself, **hidden** (`running-the-rig.md`);
  confirm from the logs that they came up on the right transport and bridge; hand over a game ready
  to play. Never ask the user to run a `.bat`. **Then close every process you started and verify
  they are gone** — a live relay binds the wrong port next run; `/loop` the re-check (user, 2026-08-16).
- **The game process is the session signal — watch it, don't ask.** `EmuHawk`, `TEVI` or
  `pseudoregalia` appearing means the test has started; it exiting means done or crashed, and either
  way the scaffolding comes down. Poll `Get-Process` or arm a `Monitor` (user, 2026-08-16).
- **Report the handoff, not the plumbing**: one line — "deployed, the scaffolding is running, launch
  the game" — plus what to look for. Monitors, loops, hash and port checks are yours to do silently.
- **HOT RELOAD IS THE DEFAULT LOOP; a manual game restart is the LAST resort.** Ask a running game
  with a Lua probe, change behaviour with a dev toggle file the built mod already reads, rebuild the
  C++/C# adapter only when the change must ship in it (user, 2026-08-31; the host files say how).
- **After ~3 failed live iterations, STOP, table the results (config vs outcome), and try the
  untested COMBINATION** — "A alone does nothing, B alone does nothing" never implies A+B does
  nothing, and every cycle costs the user a game launch (2026-08-17, the slide pose).
- **Test instructions use up/down/left/right, never compass points** (user preference; code may).
- **Treat "access denied" as a question to research** (who gates it, how people get past), not a wall.
- **No worktree-isolated parallel agents for testing work**: the loop is change-then-watch in a
  running game, and a worktree cannot share that session.
- **Agent memory is for the USER, never the project.** Preferences and corrections may go there; an
  address, decision, status, risk or result goes in `agent_docs/` or the code, which the repo, the
  next session and a human all see.
- **After any `.go` commit, and at the start of a session whose recent commits touch `.go` — before
  anything else — read what CI did: `gh run list -L 5`.** The user pushes and opens a fresh chat, so
  an unread red run is the race detector or fuzzer reporting what local runs cannot; `gh run view
  <id> --log-failed`; a `fuzz-failure-corpus` artifact goes into `testdata/fuzz/<Target>/` as a test.
- **Before a session ends, append a dated entry to the active phase file** — what was tried, what
  happened, what the user said, links to the records (`agent_docs/phases/README.md`).

## Method

- **A diagnostic can break the thing it measures — and then every reading agrees with itself.**
  Probes stay off by default; audit a probe's cost before trusting it; re-run with it off before
  believing a result; never judge an effect while a probe that SPAWNS one is loaded. **"It measured
  correct" is not evidence, and a clean instrument plus a symptom the user still sees means WIDEN
  THE SUBSYSTEM, never deepen the measurement** — for anything visual: wrong PLACE, or right place
  doing the wrong THING (2026-08-16, 08-23; `checklists/before-a-probe.md`, `before-trusting-a-reading.md`).
- **Never log the value you just wrote as proof it worked — including your own EDITS.** Read it back
  through a real getter, not the local you wrote. **Grep the RESULT of every scripted edit, one edit
  per script**: a later `assert` discards earlier replacements that DID match (six lost 2026-08-26),
  and `luac -p` proves a file parses, never that your change is in it (`checklists/before-a-scripted-edit.md`).
- **Two guessed fixes failing the same way is a signal**: isolate by subtraction, never a third guess.
- **A flag flip is not a revert** unless the flag gates the WORK, not merely the decision the work
  feeds: verify it removes the cost, or revert the commit. **When a regression appears, bisect real
  commits early** — last-known-good, confirm, halve (`pitfalls.md`; `checklists/before-declaring-a-fix.md`).
- **A clean light test does not close a risk that depends on sustained load**: exercise the real
  rate and duration first (a risk closed on one round trip reopened the same day).
- **Anything on `PATH` may resolve to the wrong install, and bare `cmd` is NEVER safe: a `.bat` runs
  via `& $env:ComSpec /c`, every time.** Thrice live, a devkitPro/MSYS2 shadow each time (last
  2026-09-01: exit 0, empty output, nothing ran). Preflight covers `dev-scripts/`; your tool calls are on you.
- **Rebuild the root `meshghost*.exe` with `-o` before testing through a `.bat` launcher**: `go
  build ./...` and `go test` do not refresh them (2026-08-14; preflight's root-binaries check).

## Records and docs

- **`agent_docs/status.md` is an index of what's open: two lines per item, maximum** — what is open
  and where the detail lives (`claude-md-cap.md`). A third line moves to `verified.md`, `pitfalls.md`
  or the phase file behind a pointer; a fixed-and-confirmed item is deleted the moment it is; a phase
  change overwrites in place rather than appending.
- **An adapter's `README.md` is a short build story, not a log**: its "How this adapter was built"
  list is one numbered step per thing that happened, ~2-4 plain lines each, what was done and why it
  worked. Offsets, counts, failed trails and dated evidence go to the phase file, `verified.md` or
  `pitfalls.md` — link, don't inline
  (`_template/README.md`, "Writing the new adapter's own README", keeps the one standing exception).
- **When the user confirms a fix, write HOW it was found before moving on** — the wrong theories and
  why they looked right, the measurement that settled it, what to reach for first next time. Symptom
  → cause → fix to `pitfalls.md`; a new way to MEASURE to `_template/probes.md`; a rule a new adapter
  should start with to `_template/README.md`. A fix recorded without its method gets re-derived.
- **A change to `contract.md` is a contract revision**: a new file in `agent_docs/adr/`, indexed in
  `architecture.md`.

## Read before

- **`/new-adapter` before a new game's first file exists; `/write-a-probe` before any probe.** Then
  read `adapters/_template/README.md` END TO END — `wc -l` it; short of the last line is not read
  (2026-08-17, twice the answer sat further down the file).
- **`agent_docs/checklists/` — the page for what you are about to do, BEFORE doing it** (a probe, a
  reading, a fix, a scripted edit, mirroring state, Unreal, Lua, the network); `pitfalls.md` says how
  a lesson is filed. `beyond-cosmetic.md` before anything past Tier 2; `scaling.md` before efficiency
  or scale work on the Go side; `effect-investigation.md` before effect/VFX work; `testing.md` before
  adding a test or chasing a flake; `playing.md` before driving a running game yourself.
- **`adapters/CLAUDE.md` and the host `CLAUDE.md`s load themselves on first contact with their folder
  and are never restated here or in `_template/`** — a rule with two homes drifts, twice shown here.
- **`_template/` is the gold standard and never lags**: a rule, file or trap added to a shipped adapter
  is back-ported in the same pass, and a decision that invalidates a premise there updates it.
