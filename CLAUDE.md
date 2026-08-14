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
- **"It ran without errors" is not evidence.** The standard is: was the expected thing seen
  happening on screen in a running game? A wrong memory address returns a plausible number
  instead of crashing.
- **`agent_docs/verified.md` is append-only and human-gated.** Nothing goes in it until the
  user has watched the behavior happen. Never write a "confirmed" entry on the strength of a
  successful build or a plausible-looking read.
- **The core never touches the game.** No game memory access, no rendering primitives, no
  `if game == "emerald"` branching anywhere in `internal/core` or `internal/relay`.
- **Adapters never speak the relay protocol.** An adapter may hold a socket to its own local
  core process (the bridge) and nothing else — it never learns a relay address and never
  sends bytes off-machine directly. See `agent_docs/contract.md` for the bridge/relay split.
- **`area_id` and `anim` are opaque to the core.** Compare by equality only. Never build a
  universal animation vocabulary or branch on area contents in game-agnostic code.
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
- **This is a public repo — never hardcode a personal username, absolute personal file path,
  or other machine-identifying detail into a tracked file or script.** Genericize it (a
  placeholder a new user edits, an environment variable) or make it relative instead (e.g.
  scripts under `adapters/` resolve their own directory rather than assuming one). Found live
  2026-08-11: a Phase 2 script had a hardcoded personal path that only ever worked on the
  machine it was written on — a real portability bug, not just a style nit.
  `agent_docs/environment.md` is the one deliberate exception (it's a factual environment
  record, not a template) — but even there, prefer the fact that actually matters (a version
  number) over an incidental personal detail (a full path containing a username) when either
  would do.
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
- **When giving the user test/local-testing instructions, use plain directions (up/down/
  left/right), never compass points.** User preference, specifically about talking to them —
  compass directions (north/south/east/west) remain fine anywhere in code/comments where
  that's the clearer choice.
- **Keep `agent_docs/status.md` to one screen (~50 lines).** It drifted to 628 lines once before
  (Found live 2026-08-15) by accreting a "Current focus:" bullet per session instead of updating
  the existing one — when the active phase changes, overwrite the relevant line/section instead
  of appending a new one, and move anything narrative into the relevant
  `agent_docs/phases/phaseN.md` instead.

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
- `agent_docs/phases/` holds a file per phase, kept as an archive after the phase ends.
- `agent_docs/environment.md` is the toolchain/tool/mod version record, filled in as phases
  actually run.
- `agent_docs/verified.md` is the append-only log for confirmed runtime facts.

Use this file only for working notes and rules that must be immediately visible to the
agent. Put longer design rationale, contract definitions, and phase planning into
`agent_docs/`.
