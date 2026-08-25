# Working notes for Claude

MeshGhost is an online multiplayer layer for singleplayer games; its shipped default is
cosmetic ghosts, and deeper planes exist but are opt-in and unused — see `agent_docs/brief.md`
for the design vision and `agent_docs/contract.md` for the implemented contract. Read both
before proposing a plan that touches the core, an adapter, or the relay.

## RULE 0 — THE 300-LINE CAP. Outranks every other rule in this file, without exception.

**This is the single most important rule in the project. Every rule below exists only because this
one is kept.**

**Before adding a single line here, run `wc -l CLAUDE.md`.** If the result would exceed 300,
**you may not add it** — first remove or relocate something, verify the count, then add. There is
no version of this where the file goes over "temporarily". Not "trim later", not "just this once",
not "this rule is important enough to justify it" — that last one is how every over-cap file in
history got that way. **A change that breaks the cap is not a change, it is a regression**, and it
is reverted like one.

**The question is never "can I add this?" It is "what comes out to make room?"** Answer that first,
in the same edit. If nothing can come out, the new rule is not important enough to be here.

**Why this outranks everything:** past roughly 150-200 followable instructions, obedience degrades
*uniformly* — every rule gets followed slightly worse, including the ones that exist because
something already went wrong once. So an over-cap file does not enforce more, it enforces
everything less. **A 400-line CLAUDE.md is a weaker CLAUDE.md.** Adding a rule past the cap does
not add a rule; it silently damages all the others.

Adding a rule is nearly always right; adding an *explanation* of a rule usually isn't — the rule
stays here, its reasoning goes to `agent_docs/`, with a one-line pointer. Full evidence:
`agent_docs/claude-md-cap.md`.

## Hard rules

- **No addresses or APIs from memory.** Every memory offset, hook, and third-party API call
  must be traceable to a specific file in a repo or a documentation page. If asked "where did
  this come from?" there must be an answer. Anything that looks suspiciously tidy is invented
  until confirmed against the actual source.
- **"It ran without errors" is not evidence — for an adapter.** The standard there is: was the
  expected thing seen happening on screen in a running game? A wrong memory address or a wrong
  reflected name returns a plausible number instead of crashing, so only watching settles it.
  **Never assume what a game is MEANT to do — ASK.** A change to what the player SEES needs the
  user's confirmation of intent first: reasoning from the code is how TEVI's pause-menu ghosts got
  "fixed" into a regression that wasn't (2026-08-18). Name the exact state too — **"main menu",
  never bare "menu"** — in a game with both, that word alone caused the same false alarm.
- **The Go client/server is the opposite case: confirm it with the tools, yourself, and don't ask
  the user to watch it.** `core`, `relay`, `transport`, `bridge` and `cmd/` are deterministic code
  against a contract we own — nothing there rests on a guess about a game, which is exactly why the
  three are separated. Before calling a change to them done, run `dev-scripts/run-gotests.bat` —
  build, vet, and the whole suite twice, including `internal/e2e`, which launches the real binaries
  and drives a real adapter over the bridge (no game, no watching). **`-race` runs locally too now**
  (`dev-scripts/run-gotests-race.bat`, fixed 2026-08-18) — run it when touching concurrency. Only
  fuzzing and cross-compiling are CI-only, so a green script is not a green CI. Repeat the suite
  too: `-count=10` has caught what `-count=1` and `-count=2` both miss, most recently 2026-08-16.
  A behaviour change wants a regression test that fails without the fix.
- **After any `.go` commit, go look at what CI did with it — `gh run list -L 5` — and at the start
  of a session, before anything else, if the recent commits touch `.go` files.** The user commits,
  pushes, and then opens a fresh chat, so a session usually begins with a run already finished
  that nobody has read. An unread red run is the race detector or the fuzzer reporting the exact
  class of bug local runs cannot catch. `gh run view <id> --log-failed` gets the detail; a fuzz
  failure's reproducing input downloads as the `fuzz-failure-corpus` artifact and belongs in
  `testdata/fuzz/<Target>/` as a regression test.
- **`agent_docs/verified.md` is append-only, and NOTHING adapter/game-side on the BASE/VANILLA
  game goes in it — or gets called "verified"/"confirmed" — until the USER confirms it on screen.
  Tightened 2026-08-21: no probe log, console read, or screenshot of yours substitutes there;
  your measurements go to `unverified.md`, as measurements. **A patched ROM (Archipelago etc.)
  stays yours to confirm visually — say so.** Go-side facts too. **Why: `testing.md`'s top.**
- **THE BAR IS 1:1** — user, 2026-08-19: *"not sloppy/bandage/good enought"*, and *"1:1 = it looks
  exactly the same as the player doing it"*. **Judged ON SCREEN, not by matching numbers**: copying
  a state the game never displayed is not 1:1. "Close" and "only during the transition" are OPEN.
  **Never offer a rate/tick/architecture change as the answer — that is an excuse for the defect.**
  Fix the cause. `BANDAGES.md` for real debt; read the game's own asset, never a lookalike.
- **Nothing that SHIPS writes a save, game state, or a ROM patch — ever, not even as a feature.**
  Holds whatever gets added later; the event/lease/escrow/world planes make "just write the item
  in" newly tempting, world custody worst. **Emulator adapters are Lua-only: never touching the ROM
  is what lets us run on top of an Archipelago seed** (ADR 08-21). **Dev-only test tooling MAY
  cheat** — a probe, never an adapter (2026-08-18). `plans.md`; `_template/README.md` the line.
- **The core never touches the game — and no config or feature may make it game-aware, ever.** No
  game memory, no rendering primitives, no `if game == "emerald"` in `core` or `relay`. ADR 08-20.
- **Adapters never speak the relay protocol.** An adapter may hold a socket to its own local
  core process (the bridge) and nothing else — it never learns a relay address and never
  sends bytes off-machine directly. See `agent_docs/contract.md` for the bridge/relay split.
- **`area_id` and `anim` are opaque to the core.** Compare by equality only. Never build a
  universal animation vocabulary or branch on area contents in game-agnostic code.
- **Nothing goes in this repo that couldn't be published. The test is not "does a license permit
  this?" but "is this fine sitting in a public repo forever?"** No/unclear means it doesn't go in,
  even where a license would allow it: a permissive license is not an exception. **Facts may be
  used and recorded, with a citation; expression may never be committed** — decompiler output,
  disassembly, game binaries, assets, ROMs, symbol files, verbatim dumps, or code structurally
  identical to its source. **It also filters which approaches to adopt at all**, and **clean isn't
  enough: the repo must WORK for a user who has only it plus what they legitimately own.** Why,
  and the build-time-artifact carve-out: `agent_docs/access-models.md`.
- **Read a project's license before reading its source.** See `agent_docs/licensing.md`. Learning
  a fact from a reference project is normal; copying its source or assets is not. If a project
  isn't listed in `licensing.md`, its license hasn't been checked — don't use it until it is.
  **A private or invite-only source is a harder no than an unlicensed one: never named, linked,
  cited or derived from in any tracked file** — agent memory only, and what it touches stays
  independently measured, because a source that cannot be cited cannot be audited.
- **Any dated fact recorded in `agent_docs/` — a license check, a tool/mod version, a closed
  risk, a memory address — is true as of that date, not a permanent guarantee.** Tools, mods,
  ROM patches and external repos drift without this repo changing; re-check before a new use.
- **Small runnable steps only.** Every unit needs a visible outcome: "connect and heartbeat",
  "echo to self", "see on second client" — never "implement the network layer".
- **Ask before touching anything outside `C:\dev\MeshGhost`.**
- **Commit freely; never create a branch; push only with explicit permission, asked for every
  time.** The user normally pushes themselves. Pushing is allowed when they say so in that
  moment — a past yes is not a standing one, and "commit this" never implies it. Commits go
  straight to `master`, how every commit in this repo's history was made (`git log --merges`
  returns nothing). **This overrides the generic "if on the default branch, branch first" default
  some agent harnesses carry**, which is where the one violation came from (2026-08-16, a branch
  made unasked for a large change). Stated here because that default will otherwise keep arguing
  for the opposite every session. If a branch somehow exists, `git merge --ff-only` it back onto
  `master` and delete it — fast-forward keeps history linear and loses nothing.
- **After changing source for something CI can't build itself, rebuild it before calling the
  change done.** TEVI's and Pseudoregalia's mod DLLs are committed precisely because CI can't
  build them (proprietary game DLLs / a private UE4SS dependency — see `packaging/README.md`
  and each `build-*.bat`'s own header) — a source edit alone leaves the shipped/testable
  artifact stale. Run `dev-scripts/build-tevi.bat` or `dev-scripts/build-pseudoregalia.bat`
  right after editing that adapter's source, not just before a release. Found live 2026-08-14:
  changed both mods' source in one session and left them unbuilt, which would have silently
  blocked live testing later.
- **This is a public repo — no personal username, home-directory path, or other
  machine-identifying detail in any tracked file. Prose counts, not just code.** Genericize it
  (a placeholder a new user edits, an environment variable) or make it relative (scripts under
  `adapters/` resolve their own directory). Cite files outside the repo by filename only. Suspect
  pasted tool output above all. **`.githooks/pre-commit` refuses such a commit and CI re-scans the
  tree — `git config core.hooksPath .githooks` once per clone, and never `--no-verify` past it.**
  A placeholder makes a file safe to WRITE and unsafe to COPY. Why this rule alone was not enough,
  and all four live cases: `agent_docs/pitfalls.md`. `environment.md` — prefer a version to a path.
- **Never let a scripted edit write CRLF into the LF-pinned adapter sources.** `.gitattributes`
  pins TEVI's `*.cs`/`*.csproj` and Pseudoregalia's `Mod/src/*.cpp|hpp`/`CMakeLists.txt` to
  `eol=lf`, because the release staleness gate hashes them on a Windows runner that defaults to
  `core.autocrlf=true`. A `python`/`perl`/heredoc edit that emits `\r\n` leaves the working tree
  disagreeing with what git stores, so the hash the build bakes into `*-built-from.txt` can never
  match CI's checkout — the gate then fails claiming the DLL is stale when it is perfectly fresh,
  and rebuilding "to fix it" just re-bakes the same wrong hash. **Order matters: normalize first,
  then build, then commit.** After any scripted edit to those files, `file <path>` must not say
  CRLF (`perl -pi -e 's/\r\n/\n/g'` fixes it). Prefer the Edit tool, which respects the existing
  endings. Found live twice, most recently 2026-08-15.
- **Rebuild the Go binaries before testing via a `.bat` launcher, not just before shipping.**
  `go build ./...`/`go vet`/`go test` don't refresh `meshghost.exe`/`meshghost-relay.exe`/
  `meshghost-fakeadapter.exe`/`meshghost-netsim.exe` at the repo root — `dev-scripts/*.bat` launches those exact named
  binaries. Rebuild explicitly with `-o` first. Found live 2026-08-14: a bug repro ran against
  binaries a full day stale.
- **Never log the value you just wrote as proof it worked — this covers your own EDITS.** Read back
  independently: a real getter, not the local you wrote; and re-read the FILE after any scripted
  edit, because an unmatched pattern fails SILENTLY. 2026-08-21: "fixed in both" was false.
- **Two guessed fixes failing the same way is a signal.** Isolate by subtraction, never a third guess.
- **After ~3 failed live-test iterations, STOP and write the results as a table (config vs
  outcome) before building anything else — and try the untested COMBINATION.** "A alone does
  nothing, B alone does nothing" never implies A+B does nothing; game code is full of
  preconditions. Every live cycle costs the user a real game launch, so grinding one-variable
  changes at them is expensive in *their* time. Found live 2026-08-17: ten cycles into the slide
  pose, the user asked "have we tried a run with everything put together, if they need each other
  to work?" — and the one run with both the capsule mirror and the crouch input on was the only
  one that ever worked. It had been sitting in my own results for several cycles.
- **If a game has a cleared decompilation, READ IT FIRST.** `licensing.md` clears all four `pret`
  decomps for facts-with-a-citation and `environment.md` records them built locally — field names,
  flag bits and dispatch order are all sitting there. **Measurement is for CONFIRMING what the
  source says, not for discovering it**, and a probe cannot tell you what a byte MEANS. Live
  2026-08-23: a ghost cloned a trainer and hung the game; the source named it. `pitfalls.md`.
- **A clean light test does not close a risk that depends on sustained load.** Exercise the real
  rate/duration before marking it closed — found live: a single successful round trip closed a risk
  that reopened the same day once real sustained traffic was tried.
- **Treat "access denied" as a question to research, not a wall** — who gates it, how do people
  get past it — before investing in a workaround.
- **Anything on `PATH` may resolve to the wrong install — including `cmd` itself.** Confirm the
  real copy (`C:\Program Files\CMake\bin`, `$env:ComSpec`) before believing a build failure;
  prefer an absolute path for the interpreter. Twice live, both a devkitPro/MSYS2 shadow:
  2026-08-13 `cmake` (a fake `CMAKE_GENERATOR` failure), 2026-08-17 `cmd`. See `pitfalls.md`.
- **Don't use worktree-isolated parallel agents for testing work here.** The test loop is "make
  a change, then watch it live in a running BizHawk/game session" — a git worktree can't share
  that live, stateful session, so parallelizing testing across worktrees doesn't fit how this
  project is actually verified.
- **Keep working through to completion; don't suggest stopping partway.** Only pause to ask if
  genuinely blocked — a real technical dead end, or a decision only the user can make — not as
  a default checkpoint.
- **NEVER suggest stopping, pausing, or resuming later — including as one option among several.**
  Never invoke the clock, session length, or attempt count. Banned: "it's late", "good place to
  stop", "pick it up fresh", "stop here for tonight", and every variation, in prose OR as an
  `AskUserQuestion` choice. **Offering it as a choice is suggesting it**; that loophole was used
  the same day the rule was written (2026-08-17), reasoning that a menu entry is not a suggestion.
  **Silence means keep going until it actually works** — the user says when to stop. If genuinely
  blocked, name the blocker and the next measurement instead.
- **A diagnostic can break the thing it measures — and then every reading agrees with itself.**
  Keep probes off by default, audit their cost before trusting their output, and re-run with them
  off before believing a result. Never leave a probe that *spawns* an effect enabled while judging
  that effect. Numbers gathered while a heavy probe was live are retroactively suspect; the shapes
  that cost most are in `_template/probes.md`. **"It measured correct" is not evidence**, the same
  way "it ran without errors" isn't. **A clean instrument plus a symptom the user still sees means
  WIDEN THE SUBSYSTEM, never deepen the measurement** — for anything visual, ask whether it is in
  the wrong PLACE or the right place doing the wrong THING. Live 2026-08-16, and all of 08-23.
- **A flag flip is not a revert.** A `constexpr bool` only reverts behaviour if it gates the *work*,
  not merely the decision the work feeds — otherwise an A/B "proves" a change innocent while its
  cost still runs. Verify the flag disables the cost, or revert the commit. **When a regression
  appears, bisect real commits early**: last-known-good, confirm, halve — mechanical, needs no
  theory, and cannot be fooled by a partial revert. Both cases, dated: `pitfalls.md`.
- **Cite dates, not durations — INCLUDING a duration used only for emphasis** ("for months",
  "long-standing"). Repo born 2026-08-11, so these are false on arrival and worse with age. Live
  2026-08-16 ×3; 2026-08-21, "for months" about a two-day-old rule; 2026-08-23, "for days".
- **Test instructions use plain directions (up/down/left/right), never compass points.** User
  preference, about talking to them — compass points stay fine in code and comments.
- **You run the scaffolding for a live test; the user only opens and closes the game.** Start the
  relay, the core, and any `dev-scripts` launcher yourself, confirm from the logs that they came
  up and that the right transport/bridge was actually chosen, and hand over a game that is ready
  to play. Never ask the user to run a `.bat`. Start them **hidden** (`environment.md`).
  **Then close every process you started, and verify they are gone** — leaving relays alive is how a later run silently binds the wrong port. If the
  test is still pending after a long wait, or has just been confirmed, **use `/loop` to re-check
  and close them** rather than trusting that you will remember. User preference, 2026-08-16.
- **The game process is the session signal — watch it, don't ask.** `EmuHawk`, `TEVI`,
  `pseudoregalia` appearing means the test has started; **it exiting means the user is done or the
  game crashed, and either way the scaffolding above should be shut down.** Poll with
  `Get-Process`, or arm a `Monitor` on it so the exit wakes you. Do not sit waiting to be told a
  run has finished when the process list already says so. User preference, 2026-08-16.
- **Report the handoff, not the plumbing: "deployed, the scaffolding is running, launch the game"
  plus what to look for.** Monitors, loops, hash checks, port checks and process restarts are your
  business — do them, don't narrate them. The user needs one line telling them it is their turn.
  User preference, 2026-08-16.
- **An adapter's `README.md` is a short build story, not a log.** Its "How this adapter was
  built" list stays plain and skimmable: **one numbered step per thing that happened, ~2-4 lines
  each**, saying what was done and why it worked, in the language you'd use explaining it out
  loud. Field names, offsets, dump counts, sample sizes, failed-attempt trails, and dated
  evidence go to `agent_docs/phases/phaseN.md`, `verified.md`, or `pitfalls.md` — link, don't
  inline. When a step starts needing bold sub-clauses or a paragraph of caveats, that's the
  signal it belongs in the phase file with a one-line pointer left behind. The time-figure rule,
  the evidence, and the ONE standing exception that must not be trimmed: `_template/README.md`.
- **When the user confirms a fix, write down HOW it was found before moving on — in the same
  pass, not later.** Confirmation is when the method is proven, and the method outlasts the fix:
  a fix helps one game, a better way to FIND things helps every adapter after it. Say what the
  wrong theories were and why they looked right, what measurement finally settled it, and what to
  reach for first next time. Symptom → cause → fix goes to `pitfalls.md`; a new way to
  MEASURE to `_template/probes.md`; a rule a new adapter should start with to
  `_template/README.md`. A fix recorded with no method is a fix that gets re-derived.
- **Agent memory is for the USER, never the project.** Preferences, ways of working and corrections
  may go there. **A project fact never does** — an address, decision, status, risk or result belongs
  in `agent_docs/` or the code, which the repo, the next session and a human all see. Memory is
  invisible to all three and goes stale with nothing to catch it.
- **`agent_docs/status.md` is an index of what's open, not a record: two lines per item, maximum —
  what is open, and where the detail lives.** A third line means it belongs in `verified.md`,
  `pitfalls.md`, or `phases/phaseN.md`; move it and leave a pointer. Delete an item the moment it's
  fixed and confirmed, and overwrite in place when the active phase changes rather than appending.
  Why per-item and not a flat line cap: `agent_docs/claude-md-cap.md`.

## Internal docs conventions

`agent_docs/README.md` is the index: every internal doc, what it holds, and when to read it.
Start there, not here. Below are only the pointers that carry a RULE — this file is always
loaded and that index is not, so a trigger kept here still fires and a description does not.

- Each adapter's `FLAGS.md` is its compile-time flag register. **When a flag's comment and its
  value disagree, the register and the value win.** Flags that only work as a set are marked
  there; do not switch one off alone.
- Each adapter's `documentation.md` records **how that GAME works**. **Hard rule: no bandages in
  it, ever** — only what the game itself properly handles. Everything in it must be publishable:
  facts observed from a running copy, never source, decompiled output, asset content or verbatim
  dumps (`licensing.md`).
- `agent_docs/beyond-cosmetic.md` — read before proposing anything past Tier 2.
- `agent_docs/effect-investigation.md` — read before starting effect/VFX work on a new adapter,
  not after it goes wrong.
- `agent_docs/testing.md` — read before adding a test or chasing a flake.
- `agent_docs/playing.md` — read before driving a running game yourself.
- A change to `contract.md` is a contract revision: record it as an ADR in `architecture.md`.
- **Invoke `/new-adapter` before a new game's adapter exists — before you create its first file —
  and `/write-a-probe` before writing any probe.** Each sequences the required reading in the
  order the work needs it. **Then read `adapters/_template/README.md` END TO END; `wc -l` it, and
  if you have not reached the last line you have not read it.** Reading the top and starting work
  is THE failure mode — it happened twice on 2026-08-17, both times with the answer sitting
  further down the file. **Answers are at the bottom as often as the top.**
- **`adapters/CLAUDE.md` and `adapters/bizhawk/CLAUDE.md` load themselves** on first contact with
  those folders — the every-adapter hard rules and the BizHawk host rules. Do not restate either
  here, or in `_template/`: a rule with two homes drifts, and this repo can show that twice.
- **`_template/` is the gold standard and may never lag**: a rule, file or trap added to a shipped
  adapter is back-ported in the same pass, and a decision that invalidates a premise there updates it.

Use this file only for working notes and rules that must be immediately visible to the
agent. Put longer design rationale, contract definitions, and phase planning into
`agent_docs/`.
