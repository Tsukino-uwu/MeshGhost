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
- **`agent_docs/verified.md` is append-only, and human-gated for anything visual ON THE VANILLA
  ROM** — there a screenshot you took is NOT a substitute, ever. **On a patched/modified ROM
  (Archipelago etc.) you MAY confirm visually yourself, from your own screenshot** — say so.
  A fact from a log line, a console read, or the Go tools may be recorded without waiting — say
  which. Never write "confirmed" on a build or a plausible read. **Why: `testing.md`'s top.**
- **THE BAR IS 1:1** — user, 2026-08-19: *"not sloppy/bandage/good enought"*, and *"1:1 = it looks
  exactly the same as the player doing it"*. **Judged ON SCREEN, not by matching numbers**: copying
  a state the game never displayed is not 1:1. "Close" and "only during the transition" are OPEN.
  **Never offer a rate/tick/architecture change as the answer — that is an excuse for the defect.**
  Fix the cause. `BANDAGES.md` for real debt; read the game's own asset, never a lookalike.
- **Nothing that SHIPS writes a save or game state — ever, not even as a feature.** Holds whatever
  gets added later; the event/lease/escrow/world planes make "just write the item in" newly
  tempting, world custody worst. **Dev-only test tooling MAY cheat** — a probe, never an adapter;
  saves are expendable in testing (user, 2026-08-18). `plans.md`; `_template/README.md` the line.
- **The core never touches the game.** No game memory access, no rendering primitives, no
  `if game == "emerald"` branching anywhere in `core` or `relay`.
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
  pasted tool output above all. Never assume a clean run means clean —
  `git grep -inIF -e 'C:\Users' -e 'C:/Users' -e '/home/' -- . ':!CLAUDE.md'
  ':!agent_docs/environment.md' ':!agent_docs/pitfalls.md' ':!dev-scripts/preflight.ps1'` must
  print nothing; **both slash directions and `-F` are load-bearing** (why, and all three live
  cases: `agent_docs/pitfalls.md`). `agent_docs/environment.md` — prefer a version to a path.
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
- **Never log the value you just wrote as proof it worked.** Read back an independent value
  instead (e.g. a real getter call, not the local variable you wrote into) — an echoed log
  line proves your code ran, not that the world actually changed.
- **Two guessed fixes failing the same way is a signal.** Isolate by subtraction, never a third guess.
- **After ~3 failed live-test iterations, STOP and write the results as a table (config vs
  outcome) before building anything else — and try the untested COMBINATION.** "A alone does
  nothing, B alone does nothing" never implies A+B does nothing; game code is full of
  preconditions. Every live cycle costs the user a real game launch, so grinding one-variable
  changes at them is expensive in *their* time. Found live 2026-08-17: ten cycles into the slide
  pose, the user asked "have we tried a run with everything put together, if they need each other
  to work?" — and the one run with both the capsule mirror and the crouch input on was the only
  one that ever worked. It had been sitting in my own results for several cycles.
- **Never go quiet for a long stretch.** The user cannot tell a loop from long thinking — both
  read as stuck, and they had to interrupt to break it (2026-08-17). Say what you are about to do,
  keep turns short while investigating, and never let a `/loop`, a monitor, or more deliberation
  stand in for making a decision. If you are thrashing, say so with the table and the remaining
  candidates.
- **A clean light test does not close a risk that depends on sustained load.** Exercise the
  real rate/duration before marking it closed — a one-shot round trip and a real sustained
  stream can behave completely differently. Found live: a single successful round trip closed
  a risk that reopened the same day once tested under real sustained traffic.
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
  that effect. Per-tick enumeration on the game thread is the expensive shape — especially with a
  name lookup or string conversion per object; compare by pointer instead. Numbers gathered while a
  heavy probe was live are retroactively suspect. **"It measured correct" is not evidence**, the
  same way "it ran without errors" isn't; and if the user reports a difference the metrics deny,
  the metrics are the suspect. Found live 2026-08-16 — the worst regression this project has had.
- **A flag flip is not a revert.** A `constexpr bool` only reverts behaviour if it gates the *work*,
  not merely the decision the work feeds — otherwise an A/B "proves" a change innocent while its
  cost is still running, which is exactly what misdirected the 2026-08-16 investigation. Verify the
  flag disables the cost, or revert the commit. **When a regression appears, bisect real commits
  early**: build the last-known-good commit, confirm it is good, then halve. It is mechanical,
  needs no theory, and can't be fooled by a partial revert.
- **Cite dates, not durations.** "since 2026-08-15", never "for a year" — this repo is days old
  (first commit 2026-08-11), so invented durations are false on arrival and worse with age.
  Found live 2026-08-16, three times, all describing five-day-old code.
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
  signal it belongs in the phase file with a one-line pointer left behind. Any time figure is
  **time to reach a named milestone, not total time spent** ("~10 hours from nothing to good
  enough", not "~10 hours in") — all four adapter READMEs read that way, and it's
  the number a reader is actually asking for. Found live 2026-08-15:
  Pseudoregalia's steps 19-22 had each grown to 15-20 dense lines while 1-18 stayed at 2-4,
  making the file hard to read for exactly the audience it's for. **Standing exception, granted by
  the user 2026-08-16 and extended 2026-08-17: Pseudoregalia's steps 38-41 (ultra-hop blue trail)
  and 43-44 (the slide pose) run 6-10 lines each and must not be trimmed** — the adapter's two
  hardest pieces of work. A note at the bottom of that list says so too; don't "fix" either.
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

- `README.md` is the public repo landing page; `agent_docs/README.md` is the internal doc index.
- `agent_docs/brief.md` is the original design brief — vision and rationale.
  `agent_docs/project-history.md` is the retrospective on the pre-planning phase, before any
  adapter existed — per-adapter build stories live in each game's own `README.md` instead.
- `agent_docs/contract.md` is the implemented packet schema, adapter interface, and transport
  contract. This is the most durable file in the repo; changes to it are contract revisions,
  recorded as ADRs in `architecture.md`.
- `agent_docs/architecture.md` is for system shape and the architecture decision log;
  `agent_docs/plans.md` is for the live roadmap, phase status, and non-goals.
- `agent_docs/ideas.md` is the unscheduled backlog — nothing there is committed until it moves
  into `plans.md`.
- `agent_docs/status.md` is the one-screen summary of the active phase and current focus — the
  file a session actually needs first to know where work stands.
- `agent_docs/licensing.md` is the third-party license audit — check before referencing a project.
- `agent_docs/risks.md` is the assumptions and risk register; `agent_docs/pitfalls.md` is the
  adapter-specific issues log — symptom, diagnosis, fix.
- `agent_docs/beyond-cosmetic.md` is the concept layer under `plans.md`'s depth ladder — sync
  models, the authority taxonomy, and what a deeper-than-cosmetic mode would need. Nothing in it
  is scheduled or approved; read it before proposing anything past Tier 2.
- `agent_docs/bandages-core.md` is the Go side's shipped-compensation register. Each adapter has
  its own `BANDAGES.md` next to its `README.md`; `adapters/_template/BANDAGES.md` holds the
  how-to-tell-a-bandage guide, including the tells that only appear after the fact.
- Each adapter's `FLAGS.md` is its compile-time flag register — every switch sorted into shipped
  **behaviour**, **probe** (off, and a probe can break what it measures), or **dormant** negative.
  **When a flag's comment and its value disagree, the register and the value win.** Flags that
  only work as a set are marked there; do not switch one off alone.
- Each adapter's `documentation.md` records **how that GAME works** — per mechanic: the fields,
  the components, what it actually does. **Hard rule: no bandages in it, ever** — only behaviour
  the game itself properly handles, so it reads as a description of the game to someone who has
  never seen our code. Everything in it must also be publishable: facts observed from a running
  copy, never source, decompiled output, asset content or verbatim dumps (`licensing.md`).
- **Read `adapters/_template/README.md` END TO END before a new game's adapter exists — every
  line, before you create its first file. `wc -l` it; if you have not reached the last line, you
  have not read it, and saying "I read the template" is then false.** Reading the top and starting
  work is THE failure mode, not a shortcut — it happened twice on 2026-08-17, the day this rule
  was written, both times with the answer already sitting further down the file. **Answers are at
  the bottom as often as the top.** It holds the folder convention, the access-model question and
  enumerate-before-guessing; its companion `adapters/_template/probes.md` is the probe method —
  read that one before writing any probe. **`_template/` is also the gold standard and may never
  lag**: a rule, file or trap added to a shipped adapter is back-ported in the same pass, and a
  decision that invalidates a premise stated there updates it.
- `agent_docs/effect-investigation.md` is the how-to-search playbook for a game's visual effects —
  read before starting effect/VFX work on a new adapter, not after it goes wrong.
- `agent_docs/access-models.md`: what can be read about each game, and why it predicts difficulty.
- `agent_docs/phases/` archives a file per phase; `agent_docs/environment.md` is the toolchain and
  tool/mod version record; `agent_docs/playing.md` is what an agent may do to a RUNNING game.
- `agent_docs/verified.md` is the append-only log for confirmed runtime facts.
- `agent_docs/testing.md` is how to run every automated Go-side check, what CI adds, and the
  testing traps worth not rediscovering. Read it before adding a test or chasing a flake.

Use this file only for working notes and rules that must be immediately visible to the
agent. Put longer design rationale, contract definitions, and phase planning into
`agent_docs/`.
