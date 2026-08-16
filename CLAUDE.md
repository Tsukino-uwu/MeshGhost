# Working notes for Claude

MeshGhost is a visual-only multiplayer layer for singleplayer games — see
`agent_docs/brief.md` for the full design vision and `agent_docs/contract.md` for the
implemented contract (packet schema, adapter interface, transport). Read both before
proposing a plan that touches the core, an adapter, or the relay.

## Hard rules

- **No addresses or APIs from memory.** Every memory offset, hook, and third-party API call
  must be traceable to a specific file in a repo or a documentation page. If asked "where did
  this come from?" there must be an answer. Anything that looks suspiciously tidy is invented
  until confirmed against the actual source.
- **"It ran without errors" is not evidence — for an adapter.** The standard there is: was the
  expected thing seen happening on screen in a running game? A wrong memory address or a wrong
  reflected name returns a plausible number instead of crashing, so only watching settles it.
- **The Go client/server is the opposite case: confirm it with the tools, yourself, and don't
  ask the user to watch it.** `internal/core`, `internal/relay`, `internal/transport`,
  `internal/bridge` and `cmd/` are deterministic code against a contract we own — nothing there
  rests on a guess about a game, which is exactly why the three are separated. Before calling a
  change to them done, run `dev-scripts/run-gotests.bat` — build, vet, and the whole suite
  twice, including `internal/e2e`, which launches the real binaries and drives a real adapter
  over the bridge (no game, no watching). CI adds the race detector and a fuzz campaign on any
  push touching a `.go` file; neither runs locally, so a green script is not a green CI. **Repeat the suite
  when touching concurrency** — `-count=10` has caught what `-count=1` and `-count=2` both
  miss, most recently 2026-08-16. A behaviour change wants a regression test that fails
  without the fix.
- **`agent_docs/verified.md` is append-only, and human-gated for anything visual.** A claim about
  what happens on screen or in gameplay goes in only after the user has watched it. A fact you
  established yourself from a log line, a console read, or the Go tools above may be recorded
  without waiting — say which it was. Never write a "confirmed" entry on the strength of a
  successful build or a plausible-looking read.
- **The core never touches the game.** No game memory access, no rendering primitives, no
  `if game == "emerald"` branching anywhere in `internal/core` or `internal/relay`.
- **Adapters never speak the relay protocol.** An adapter may hold a socket to its own local
  core process (the bridge) and nothing else — it never learns a relay address and never
  sends bytes off-machine directly. See `agent_docs/contract.md` for the bridge/relay split.
- **`area_id` and `anim` are opaque to the core.** Compare by equality only. Never build a
  universal animation vocabulary or branch on area contents in game-agnostic code.
- **Nothing goes in this repo that couldn't be published. The test is not "does a license permit
  this?" but "is this fine sitting in a public repo forever?"** If the answer is no, or unclear, it
  doesn't go in — even where a license would arguably allow it. **This is deliberately stricter than
  the licenses require**, and it's the same instinct as the no-usernames rule below: the repo
  contains only what may be public, full stop. Consulting a reference for *facts* stays allowed (next
  rule); containing its *expression* does not — which is why the `pokeemerald` decompilation can be
  read but nothing of it exists in this repo. Applies to decompiler output, disassembly, game
  binaries, assets, ROMs, symbol files, and verbatim reflection dumps alike. **It also filters which
  approaches to adopt at all: don't take one that needs unpublishable material present in the repo to
  work.** Where an approach needs a user-owned artifact only at *build* time (TEVI compiling against
  the game's own DLL), that artifact stays out and the build output is committed instead — which is
  what costs us CI builds for those two adapters. **Clean isn't enough: the public repo must also
  WORK for a user who has only it plus what they legitimately own** (their own game/ROM/emulator) —
  nothing disallowed may be required to install or run it. Consulting any reference we need stays
  fine; it just never ends up here. Per-approach detail: `agent_docs/access-models.md`.
- **Read a project's license before reading its source.** See `agent_docs/licensing.md`.
  Consulting a reference project (e.g. the `pokeemerald` decompilation) to learn a fact —
  an address, a function name, a data layout — is normal; copying its source or assets is
  not. If the project isn't already listed in `licensing.md`, its license hasn't been
  checked yet — don't use it as a reference until it is.
- **Any dated fact recorded in `agent_docs/` — a license check, a tool/mod version, a closed
  risk, a memory address — is true as of that date, not a permanent guarantee.** Installed
  tools, mods, ROM/game patches, and external repos can all drift without this repo changing.
  Re-check before relying on an old fact for a genuinely new use, not just reactively if a
  change happens to be noticed.
- **Small runnable steps only.** Every unit of work needs a visible, observable outcome.
  "Implement the network layer" is not testable; "connect and heartbeat," "echo to self,"
  "see on second client" are.
- **Ask before touching anything outside `C:\dev\MeshGhost`.**
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
  `adapters/` resolve their own directory). Cite files living outside the repo by filename
  only — an absolute prefix is unusable to a reader anyway. Suspect pasted tool output
  above all: both live cases got in that way rather than by being typed. Verify before
  committing, and never assume a clean run means clean —
  `git grep -inIF -e 'C:\Users' -e '/home/' -- . ':!CLAUDE.md' ':!agent_docs/environment.md'
  ':!agent_docs/pitfalls.md'` must print nothing (`-F` is load-bearing: as a regex the
  backslashes silently match nothing, so the check passes while leaking. The three excluded
  files contain the pattern by definition — this one, and the two that document it). `agent_docs/environment.md` is the one deliberate exception (a
  factual environment record, not a template) — even there prefer the version number over a
  path containing a username. Both found-live cases: `agent_docs/pitfalls.md`.
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
  `meshghost-fakeadapter.exe` at the repo root — `dev-scripts/*.bat` launches those exact named
  binaries. Rebuild explicitly with `-o` first. Found live 2026-08-14: a bug repro ran against
  binaries a full day stale.
- **Never log the value you just wrote as proof it worked.** Read back an independent value
  instead (e.g. a real getter call, not the local variable you wrote into) — an echoed log
  line proves your code ran, not that the world actually changed.
- **Two guessed fixes failing with the identical symptom is a signal, not bad luck.** Stop
  guessing and isolate by subtraction (one diagnostic, one variable, at a time) instead of
  trying a third.
- **A clean light test does not close a risk that depends on sustained load.** Exercise the
  real rate/duration before marking it closed — a one-shot round trip and a real sustained
  stream can behave completely differently. Found live: a single successful round trip closed
  a risk that reopened the same day once tested under real sustained traffic.
- **Treat "access denied" as a question to research, not a wall to route around** — who gates
  this, and how does anyone actually get past it — especially before investing in a workaround
  that would be expensive to undo.
- **A build tool on `PATH` may silently resolve to the wrong install.** Confirm `cmake` (and
  similar) resolves to the intended copy (e.g. `C:\Program Files\CMake\bin`, not a bundled
  MSYS2 copy) before trusting a build failure or success. Found live 2026-08-13: a
  `CMAKE_GENERATOR` failure was this, not a real toolchain regression.
- **Don't use worktree-isolated parallel agents for testing work here.** The test loop is "make
  a change, then watch it live in a running BizHawk/game session" — a git worktree can't share
  that live, stateful session, so parallelizing testing across worktrees doesn't fit how this
  project is actually verified.
- **Keep working through to completion; don't suggest stopping partway.** Only pause to ask if
  genuinely blocked — a real technical dead end, or a decision only the user can make — not as
  a default checkpoint.
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
- **Cite dates, not durations.** Write "since 2026-08-15" or "the day before", never "for a year"
  or "after months" — this repo is days old (first commit 2026-08-11; `LICENSE` carries the year),
  and invented durations are both false on arrival and worse with age. Found live 2026-08-16: three
  such claims in `pitfalls.md` and the adapter template, all describing five-day-old code.
- **When giving the user test/local-testing instructions, use plain directions (up/down/
  left/right), never compass points.** User preference, specifically about talking to them —
  compass directions (north/south/east/west) remain fine anywhere in code/comments where
  that's the clearer choice.
- **An adapter's `README.md` is a short build story, not a log.** Its "How this adapter was
  built" list stays plain and skimmable: **one numbered step per thing that happened, ~2-4 lines
  each**, saying what was done and why it worked, in the language you'd use explaining it out
  loud. Field names, offsets, dump counts, sample sizes, failed-attempt trails, and dated
  evidence go to `agent_docs/phases/phaseN.md`, `verified.md`, or `pitfalls.md` — link, don't
  inline. When a step starts needing bold sub-clauses or a paragraph of caveats, that's the
  signal it belongs in the phase file with a one-line pointer left behind. Any time figure is
  **time to reach a named milestone, not total time spent** ("~10 hours from nothing to good
  enough", not "~10 hours in") — the three existing adapter READMEs all read that way, and it's
  the number a reader is actually asking for. Found live 2026-08-15:
  Pseudoregalia's steps 19-22 had each grown to 15-20 dense lines while 1-18 stayed at 2-4,
  making the file hard to read for exactly the audience it's for. **One standing exception, granted
  by the user 2026-08-16: Pseudoregalia's steps 38-41 (the ultra-hop blue trail) run ~6 lines each
  and must not be trimmed to match the rest** — it was the adapter's hardest and longest piece of
  work. A note at the bottom of that list says so too; don't "fix" either.
- **`agent_docs/status.md` is an index of what's open, not a record: two lines per item, maximum —
  what is open, and where the detail lives.** A third line means it belongs in `verified.md`,
  `pitfalls.md`, or `phases/phaseN.md`; move it and leave a pointer. Delete an item the moment it's
  fixed and confirmed, and overwrite in place when the active phase changes rather than appending.
  **This replaced a flat ~50-line cap on 2026-08-16, because the cap was on the wrong variable**:
  it bounded the file but nothing bounded per-item verbosity, so each item arrived carrying its own
  rationale (averaging 3 lines, one reaching 6) and the total crept back — 628 lines once
  (2026-08-15), then 106 the next day even with the cap in force. Size now tracks the *number* of
  open items, which is real signal, instead of how much context each one drags along.

## This file is capped at 300 lines

**Treat the cap as a rule, not a target.**

Research cited by the humanlayer guide puts frontier thinking models at ~150–200 followable
instructions, and finds degradation is uniform, not tail-first. More instructions doesn't
mean the bottom of the file gets ignored; it means every rule above gets followed slightly
worse, including the ones that exist because something went wrong once. Source:
<https://www.humanlayer.dev/blog/writing-a-good-claude-md>

**So when this file would exceed 300 lines, something moves to `agent_docs/` — the question
is never "can I add this?" but "what comes out to make room?"** Adding a rule is nearly
always right; adding an explanation of a rule usually isn't. If a rule needs a paragraph of
reasoning, the rule stays here and the reasoning goes to a `.md` file in `agent_docs/`.

## Internal docs conventions

- `README.md` is the public repo landing page.
- `agent_docs/README.md` is the internal documentation index.
- `agent_docs/brief.md` is the original design brief — vision and rationale.
- `agent_docs/project-history.md` is the retrospective on the pre-planning phase, before any
  adapter existed — per-adapter build stories live in each game's own `README.md` instead.
- `agent_docs/contract.md` is the implemented packet schema, adapter interface, and
  transport contract. This is the most durable file in the repo; changes to it are
  contract revisions, recorded as ADRs in `architecture.md`.
- `agent_docs/architecture.md` is for system shape and the architecture decision log.
- `agent_docs/plans.md` is for the live roadmap, phase status, and non-goals.
- `agent_docs/ideas.md` is the unscheduled backlog — researched enough to act on when picked,
  but nothing there is committed until it moves into `plans.md`.
- `agent_docs/status.md` is the one-screen summary of the active phase and current focus — the
  file a session actually needs first to know where work stands.
- `agent_docs/licensing.md` is the third-party license audit — check before referencing any
  outside project.
- `agent_docs/risks.md` is the assumptions and risk register.
- `agent_docs/pitfalls.md` is the adapter-specific issues log — symptom, diagnosis, fix.
- `agent_docs/effect-investigation.md` is the how-to-search playbook for a game's visual effects —
  read before starting effect/VFX work on a new adapter, not after it goes wrong.
- `agent_docs/access-models.md` records what can be read about each game (decompilation, managed
  bytecode, runtime reflection, …) and why that predicts an adapter's difficulty.
- `agent_docs/phases/` holds a file per phase, kept as an archive after the phase ends.
- `agent_docs/environment.md` is the toolchain/tool/mod version record, filled in as phases
  actually run.
- `agent_docs/verified.md` is the append-only log for confirmed runtime facts.
- `agent_docs/testing.md` is how to run every automated Go-side check, what CI adds, and the
  testing traps worth not rediscovering. Read it before adding a test or chasing a flake.

Use this file only for working notes and rules that must be immediately visible to the
agent. Put longer design rationale, contract definitions, and phase planning into
`agent_docs/`.
