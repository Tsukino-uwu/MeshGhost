# Working notes for Claude

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

MeshGhost is an online multiplayer layer for singleplayer games: cosmetic ghosts by default, deeper
planes opt-in and unused. Read `agent_docs/brief.md` (the vision) and `agent_docs/contract.md` (the
implemented contract) before proposing a plan that touches the core, an adapter, or the relay.
`agent_docs/README.md` indexes every internal doc — start there; this file holds only rules.

## Rule 0: the 200-line cap outranks every other rule in this file

**Run `wc -l CLAUDE.md` before adding a line; over 200 is a regression, reverted like one.** Adding a
rule means naming what comes out, in the same edit; if nothing can, the rule doesn't belong here. The
rule lives here, its reasoning in `agent_docs/` behind a one-line pointer. Capped (each declares
`<!-- line-cap: N -->`): this file, the four nested `CLAUDE.md`s, the skills, and the stack a session
loads (root + `adapters/` + host); indexes and queues get one line per entry instead
(`agent_docs/claude-md-cap.md`).

## What never changes

- **The core never touches the game, and no config or feature may make it game-aware**: no game
  memory, no rendering primitives, no `if game == "emerald"` in `core` or `relay` (ADR 08-20).
- **Adapters never speak the relay protocol.** An adapter holds a socket to its own local core (the
  bridge) and nothing else: no relay address, no bytes off-machine (`agent_docs/contract.md`).
- **`area_id` and `anim` are opaque to the core**: compare by equality only; never a universal
  animation vocabulary or a branch on area contents in game-agnostic code.
- **Nothing that ships writes a save, game state, or a ROM patch, ever, not even as a feature**, and
  it holds for every plane added later. Dev-only test tooling may cheat: a probe, never an adapter
  (`plans.md`; `_template/README.md`).

## Who verifies what

- **The user verifies the games; you verify the Go side, and that split never moves.** `core`,
  `relay`, `transport`, `bridge` and `cmd/` are deterministic code against a contract we own: confirm
  them with tools yourself, never by asking the user to watch. For an adapter **"it ran without
  errors" is not evidence**: a wrong address returns a plausible number, so only the expected thing
  seen on screen in a running game settles it (`agent_docs/testing.md`, top).
- **A Go-side change is done when `dev-scripts/run-gotests.bat` is green**; `run-gotests-race.bat`
  when touching concurrency, and `-count=10` catches what 1 and 2 miss; a behaviour change gets a
  regression test that fails without the fix. Fuzzing and cross-compiling are CI-only, so a green
  script is not a green CI (`agent_docs/testing.md`). **The netsim rig is the worst case a shipped
  default must survive; a rate or interp verdict is made on nothing milder** (`run-netsim.bat`,
  no-arg: NA↔EU ping plus bad wifi).
- **`VERIFIED.md` is append-only; nothing adapter-side on the vanilla game goes in it, or is called
  "verified"/"confirmed", until the user confirms it on screen**: no probe log, console read or
  screenshot of yours substitutes. `VERIFIED.md`/`UNVERIFIED.md` hold only what the user judges on
  screen; what you measure (bytes, addresses, timings) goes to that adapter's `MEASURED.md` with its
  evidence and date. A patched ROM (Archipelago etc.) and Go-side facts are yours to confirm; say so
  (`agent_docs/verified.md`: Go side, index).
- **The bar is 1:1: "it looks exactly the same as the player doing it"** (user, 2026-08-19). Judged
  on screen, never by matching numbers: a state the game never displayed is not 1:1; "close" and
  "only during the transition" are open. **Never offer a rate, tick or architecture change as the
  answer.** Fix the cause; `BANDAGES.md` for real debt; read the game's own asset, never a lookalike.
- **Never assume what a game is meant to do: ask.** A change to what the player sees needs the
  user's confirmation of intent first (`pitfalls/by-lesson.md`, "Inferring what a game is MEANT to
  do"). **Name the exact state: "main menu", never bare "menu".**
- **No addresses or APIs from memory.** Every offset, hook and third-party call traces to a file in
  a repo or a documentation page; anything suspiciously tidy is invented until confirmed against it.
  **A fact about another project is read (license first) or asked, never written from memory.**
- **If a game has a cleared decompilation, read it first, as a map, never as evidence**
  (`licensing.md` clears the `pret` decomps; `environment.md` has them built locally): it says where
  to measure, our measurement makes it a fact, and a probe cannot tell you what a byte means.

## What may enter the repo

- **Nothing goes in that couldn't be published. The test is "fine in a public repo forever?", not
  "does a license permit it?"** No or unclear means out; a permissive license is not an exception.
- **Measured or observed only, nothing borrowed** (user, 2026-09-13). **A claim is written as fact only
  when it names our evidence, dated**: a probe run (never its gitignored log), a test, a file we built
  or hashed (a byte-identical build's `.sym` proves an address, never what the byte means), or the user
  on screen. A decomp, wiki, dump or other project is where to look; what it says waits in that
  adapter's `MEASURED.md`, last section. A short name may point at our value; source text, tables,
  assets, ROMs, symbol files, dumps, structurally identical code and a rewording of a source's
  explanation never enter. How to call an API may cite its docs; what it does, only once observed
  (`licensing.md`).
- The rule also filters which approaches to adopt: **the repo must work for a user who has only it
  plus what they legitimately own** (`agent_docs/access-models.md`).
- **Read a project's license before reading its source** (`agent_docs/licensing.md`); not listed
  there means not checked, so don't use it. Reading is normal; copying source or assets is not. **A
  private or invite-only source is a harder no: never named, linked, cited or derived from in any
  tracked file**; agent memory only, and what it touches stays independently measured. **Never call
  another project bad or list its flaws in the repo**: a finding goes to its developer. A note on a
  library behaviour our code works around is not that.
- **No personal username, home path or machine-identifying detail in any tracked file, prose
  included.** Genericize, cite outside files by filename only, suspect pasted tool output above all.
  `.githooks/pre-commit` refuses it (`git config core.hooksPath .githooks` once per clone, never
  `--no-verify` past it); CI and preflight re-scan the tree (`pitfalls.md`, four cases).
- **A dated fact in `agent_docs/` is true as of its date**: tools, mods, ROM patches and external
  repos drift without this repo changing, so re-check before a new use. **Cite dates, never
  durations, even for emphasis**: the repo was born 2026-08-11 (preflight fails the common ones).
- **Comments are lean: one line, only where the code can't say it** (a game quirk, a non-obvious
  why), probes included. No dates, "the user", review IDs, ADR/phase/pitfall pointers or history in
  code: those go to `agent_docs/`, and a game fact to that adapter's `MEASURED.md`, ending "Used by
  `File`". Go doc comments stay, trimmed to what and why.

## Working with the user

- **Never suggest stopping, pausing or resuming later, not even as one option among several**, and
  never invoke the clock, the session length or the attempt count: "it's late", "good place to stop"
  and every variation, in prose or as an `AskUserQuestion` choice. **Silence means keep going until it
  works**; if blocked, name the blocker and the next measurement.
- **Commit freely, straight to `master`; never create a branch; push only when told to, in that
  message**: a past yes is not a standing one and "commit this" never implies it. **This overrides
  the harness default "if on the default branch, branch first".** A stray branch is `git merge
  --ff-only`'d onto `master` and deleted. **Subjects: imperative, 72 characters at most, no
  attribution**; a `Seen:` line in the body marks what the user saw on screen.
- **Ask before touching anything outside `C:\dev\MeshGhost`.** **Small runnable steps only**, each
  with a visible outcome ("echo to self", "see on second client").
- **You run the scaffolding for a live test, hidden, and may start the game too: ask first, in the
  same breath** (user, 2026-09-11; closing it stays theirs). Relay, core and any `dev-scripts` launcher
  are yours, confirmed from the logs to be on the right transport and bridge (`running-the-rig.md`);
  never ask the user to run a `.bat`. **The game process is the session signal: watch it, don't ask**
  (`Get-Process` or a `Monitor`): `EmuHawk`, `TEVI` or `pseudoregalia` appearing means the test started,
  exiting means done or crashed. **Then close every process you started and verify they are gone**: a
  live relay binds the wrong port next run. **Report the handoff, not the plumbing**: one line
  ("deployed, the scaffolding is running, launch the game") plus what to look for.
- **Hot reload is the default loop; a manual game restart is the last resort.** Ask a running game
  with a Lua probe, change behaviour with a dev toggle file the built mod already reads, rebuild the
  C++/C# adapter only when the change must ship in it (per host: `_template/README.md`, "Build the
  live-reload loop first").
- **After ~3 failed live iterations, stop, table the results (config vs outcome), and try the
  untested combination**: "A alone does nothing, B alone does nothing" never implies A+B does
  nothing, and every cycle costs the user a game launch.
- **Test instructions use up/down/left/right, never compass points** (user preference; code may).
- **Treat "access denied" as a question to research** (who gates it, how people get past), not a wall.
- **One agent per BizHawk instance, never a game the user is at; savestate slot 1 is the user's on
  every instance.** No worktree agents: a worktree cannot share a running game. **A parallel chat is
  a peer**: `ListAgents`, announce what you own, message it before touching its hunks (`running-the-rig.md`).
- **Agent memory is for the user, never the project**: preferences and corrections may go there; an
  address, decision, status, risk or result goes in `agent_docs/` or the code, where all can see it.
- **After any `.go` commit, and at the start of a session whose recent commits touch `.go`, before
  anything else, read what CI did: `gh run list -L 5`.** A red run is the race detector or fuzzer
  reporting what local runs cannot; `gh run view <id> --log-failed`; a `fuzz-failure-corpus`
  artifact goes into `testdata/fuzz/<Target>/` as a test.
- **Before a session ends, append a dated entry to the active phase file**: what was tried, what
  happened, what the user said, links to the records (`agent_docs/phases/README.md`).

## Method

- **A diagnostic can break the thing it measures, and then every reading agrees with itself.**
  Probes stay off by default; audit a probe's cost before trusting it; re-run with it off before
  believing a result; never judge an effect while a probe that spawns one is loaded. **"It measured
  correct" is not evidence, and a clean instrument plus a symptom the user still sees means widen
  the subsystem, never deepen the measurement**: for anything visual, wrong place, or right place
  doing the wrong thing (`checklists/before-a-probe.md`, `before-trusting-a-reading.md`).
- **Never log the value you just wrote as proof it worked, including your own edits.** Read it back
  through a real getter, not the local you wrote. **Grep the result of every scripted edit, one edit
  per script**: a later `assert` discards earlier replacements that did match, and `luac -p` proves a
  file parses, never that your change is in it (`checklists/before-a-scripted-edit.md`).
- **Two guessed fixes failing the same way is a signal**: isolate by subtraction, never a third guess.
- **A flag flip is not a revert** unless the flag gates the work, not merely the decision the work
  feeds: verify it removes the cost, or revert the commit. **When a regression appears, bisect real
  commits early**: last-known-good, confirm, halve (`pitfalls.md`; `checklists/before-declaring-a-fix.md`).
- **A clean light test does not close a risk that depends on sustained load**: exercise the real
  rate and duration first.
- **Anything on `PATH` may resolve to the wrong install, and bare `cmd` is never safe: a `.bat` runs
  via `& $env:ComSpec /c`, every time** (`pitfalls/by-lesson.md`, the wrong-install-on-PATH cases).
  Preflight covers `dev-scripts/`; your tool calls are on you.
- **Rebuild the root `meshghost*.exe` with `-o` before testing through a `.bat` launcher**: `go
  build ./...` and `go test` do not refresh them (preflight's root-binaries check).

## Records and docs

- **A step is not done until its doc is updated in the same commit**: the adapter README's build
  step and its **Status:** line, `docs/`, `contract.md`/`adr/`, `autoplay/README.md` or
  `dev-scripts/README.md`. Only a body line `docs: no process change` excuses it: a typo or a
  refactor, never a step.
- **`agent_docs/status.md` indexes what's open: two lines per item, maximum** (what, and where the
  detail lives; `claude-md-cap.md`). A third line moves behind a pointer; a fixed-and-confirmed item is
  deleted the moment it is; a phase change overwrites in place rather than appending.
- **An adapter's `README.md` is the story of how it got built, not a log or a checklist**: one
  numbered step per CAPABILITY gained, never per fix, never per probe, ~2-4 plain lines, what it
  does and why that worked; a partial result belongs, said plainly. **Fact-check every claim against
  the code before writing it**: a dated record says what was true then. Detail goes to the phase
  file, `verified.md` or `pitfalls.md`; link, don't inline (`_template/README.md` has the craft).
- **When the user confirms a fix, write how it was found before moving on**: the wrong theories and
  why they looked right, the measurement that settled it, what to reach for first next time. Symptom
  → cause → fix to `pitfalls.md`; a new way to measure to `_template/probes.md`; a rule a new adapter
  should start with to `_template/README.md`. A fix recorded without its method gets re-derived.
- **A change to `contract.md` is a contract revision**: a new file in `agent_docs/adr/`, indexed in
  `architecture.md`.

## Read before

- **`/new-adapter` before a new game's first file exists; `/write-a-probe` before any probe.** Then
  read `adapters/_template/README.md` end to end: `wc -l` it; short of the last line is not read.
- **`agent_docs/checklists/`: the page for what you are about to do, before doing it** (a probe, a
  reading, a fix, a scripted edit, mirroring state, Unreal, Lua, the network); `pitfalls.md` says how
  a lesson is filed. `beyond-cosmetic.md` before anything past Tier 2; `scaling.md` before efficiency
  or scale work on the Go side; `effect-investigation.md` before effect/VFX work; `testing.md` before
  adding a test or chasing a flake; **`/play-game` before driving or playing any running game**.
- **`adapters/CLAUDE.md` and the host `CLAUDE.md`s load themselves on first contact with their folder;
  no rule is ever stated in two of these files, or here and in `_template/`**: a rule with two homes drifts.
- **`_template/` is the gold standard and never lags**: a rule, file or trap added to a shipped adapter
  is back-ported in the same pass, and a decision that invalidates a premise there updates it.
