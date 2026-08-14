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

## This file is capped at 300 lines

**Treat the cap as a rule, not a target.**

Research cited by the humanlayer guide puts frontier thinking models at ~150–200 followable
instructions, and finds degradation is uniform, not tail-first. More instructions doesn't
mean the bottom of the file gets ignored; it means every rule above gets followed slightly
worse, including the ones that exist because something went wrong once.

**So when this file would exceed 300 lines, something moves to `agent_docs/` — the question
is never "can I add this?" but "what comes out to make room?"** Adding a rule is nearly
always right; adding an explanation of a rule usually isn't. If a rule needs a paragraph of
reasoning, the rule stays here and the reasoning goes to a `.md` file in `agent_docs/`.

## Internal docs conventions

- `README.md` is the public repo landing page.
- `agent_docs/README.md` is the internal documentation index.
- `agent_docs/brief.md` is the original design brief — vision and rationale.
- `agent_docs/contract.md` is the implemented packet schema, adapter interface, and
  transport contract. This is the most durable file in the repo; changes to it are
  contract revisions, recorded as ADRs in `architecture.md`.
- `agent_docs/architecture.md` is for system shape and the architecture decision log.
- `agent_docs/plans.md` is for the live roadmap, phase status, and non-goals.
- `agent_docs/licensing.md` is the third-party license audit — check before referencing any
  outside project.
- `agent_docs/risks.md` is the assumptions and risk register.
- `agent_docs/pitfalls.md` is the adapter-specific issues log — symptom, diagnosis, fix.
- `agent_docs/phases/` holds a file per phase, kept as an archive after the phase ends.
- `agent_docs/verified.md` is the append-only log for confirmed runtime facts.

Use this file only for working notes and rules that must be immediately visible to the
agent. Put longer design rationale, contract definitions, and phase planning into
`agent_docs/`.
