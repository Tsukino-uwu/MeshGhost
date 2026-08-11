# MeshGhost roadmap

## INDEX

Deliberately indexed by HEADING TEXT rather than line number, since line numbers rot on

every edit. To find any entry below, grep for its text. To regenerate a numbered list:

  grep -n "^- \[ \]" plans.md

## Overview

MeshGhost is a visual-only multiplayer layer for single-player games. Each player runs an independent copy of the game, and the only networked state is enough information to render a cosmetic ghost: location, area, and animation state.

The architecture is intentionally split into:

- relay server (game-agnostic)
- core client (game-agnostic)
- adapter contract (thin boundary)
- per-game adapters (game-specific)

The first target game is Pokémon Emerald via BizHawk. The second target is Ori and the Will of the Wisps, and the third is Pseudoregalia.

## What Copilot can do now

These planning tasks are safe and useful even before code-heavy work begins:

- document the packet schema and adapter contract clearly
- define transport APIs and abstraction boundaries
- write the phase-based roadmap for implementation
- enumerate acceptance criteria for each milestone
- draft `agent_docs/verified.md`, `README.md`, and project notes
- create a task backlog for first game adapter work
- identify risks, non-goals, and the exact scope of each phase

## What should wait for a stronger model or a coding session

Do not start heavy source changes, emulator hooks, or network plumbing until Claude Pro is available or a stronger coding session is offered. The following should wait:

- large refactors or architecture rewrites in code
- risky emulator memory or hook changes without verification
- implementation of interpolation and transport before the contract is stable
- adapter code for a second game until Emerald is proven

## Acceptance criteria and non-goals

### Acceptance criteria

- Phase 1 produces confirmed Emerald memory values for local player `position`, `area_id`, and an initial `anim` tag set.
- Verification steps are documented in `agent_docs/verified.md` with source details.
- Phase 2 produces a visible overlay ghost in Emerald with hardcoded state.
- The adapter contract, transport abstraction, and invariants are documented and agreed before implementation begins.

### Non-goals for early work

- No shared game world state, physics, or collision synchronization.
- No game-specific rendering logic inside the core.
- No adapter transport or socket handling.
- No production binary encoding or performance optimization before the contract is stable.
- No second-game adapter until Phase 5 validates the template.

## Roadmap

### Phase 0 — Contract on paper

Visible outcome: documented schema and interface, plus an empty `agent_docs/verified.md`.

Tasks:

- define the packet schema for `player_id`, `seq`, `timestamp`, `area_id`, `position`, `orientation`, `anim`, `extras`
- specify the adapter interface: `get_local_state()`, `render_remote(id, state)`, `despawn_remote(id)`
- document transport abstraction: `send(bytes)` and `on_receive(cb)`
- record invariants: core never touches game, adapters never touch sockets, no game-specific branching in core
- create `agent_docs/verified.md` as an append-only fact log

### Phase 1 — Emerald read-only verification

Visible outcome: BizHawk Lua prints local player state from actual game memory.

Tasks:

- read player X/Y/map from Pokémon Emerald
- print values in BizHawk Lua and confirm motion by moving in known directions
- record confirmed addresses and sources in `agent_docs/verified.md`

### Phase 2 — Fake ghost, no network

Visible outcome: a rendered ghost in Emerald following a hardcoded offset.

Tasks:

- compute screen position from map coords plus camera scroll
- render a ghost overlay in BizHawk from hardcoded state
- verify the overlay moves correctly with the local player

### Phase 3 — Loopback

Visible outcome: one client sends its own state to the local relay and renders its ghost with latency.

Tasks:

- implement local relay server and transport loopback
- send local snapshots through the schema
- receive and render the same state via the relay
- confirm ghost appears with ~200ms delay

### Phase 4 — Two players

Visible outcome: two BizHawk clients render each other's ghosts and handle joins/drops.

Tasks:

- run a second BizHawk instance and connect both clients
- support remote state from another player
- handle `area_id` mismatch by not drawing ghosts in other maps
- confirm joins, drops, and remote motion visually

### Phase 5 — Extract the template

Visible outcome: the core runs independently of the Emerald adapter with a fake adapter stub.

Tasks:

- separate core logic from Emerald-specific code
- build a fake adapter that moves a ghost in a circle
- verify the core works with the fake adapter and no game attached
- freeze the adapter contract as the reusable template

### Phase 6 — Second game

Visible outcome: repeat the prior sequence for Ori (or another second game) and validate the contract.

Tasks:

- implement the second adapter using the same contract
- run phases 3–4 for the second game
- evaluate contract quality and adjust if needed

## Recommended immediate action

Start by locking down Phase 0:

1. finalize the packet schema and adapter interface in docs,
2. confirm the transport abstraction,
3. create `agent_docs/verified.md`,
4. write the first task backlog for Emerald.

This keeps the repo moving without touching implementation details or risking code quality.

## Links

- `agent_docs/README.md` — internal documentation index.
- `agent_docs/glossary.md` — project terminology.
- `agent_docs/phases/README.md` — phase-based documentation index.
- `agent_docs/phases/phase0.md` — Phase 0 contract, checklist, and Emerald backlog.
- `agent_docs/phases/phase1.md` — Phase 1 Emerald read-only verification.
- `agent_docs/phases/phase2.md` — Phase 2 fake ghost, no network.
- `agent_docs/phases/phase3.md` — Phase 3 loopback network validation.
- `agent_docs/phases/phase4.md` — Phase 4 two-player multiplayer validation.
- `agent_docs/phases/phase5.md` — Phase 5 reusable core template extraction.
- `agent_docs/phases/phase6.md` — Phase 6 second game adapter validation.
- `agent_docs/risks.md` — project assumptions and risk register.
- `agent_docs/architecture-decisions.md` — recorded rationale for major architecture choices.
- `agent_docs/status.md` — the current active phase and project focus.
- `agent_docs/verified.md` — append-only verification log.
