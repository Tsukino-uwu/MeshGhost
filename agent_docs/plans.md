# MeshGhost roadmap

## Overview

MeshGhost is a visual-only multiplayer layer for single-player games. Each player runs an
independent copy of the game, and the only networked state is enough information to render
a cosmetic ghost: location, area, and animation state. Full rationale in `agent_docs/brief.md`.

The architecture is split into: relay server (game-agnostic), core client (game-agnostic),
adapter contract (thin boundary), per-game adapters (game-specific rewrite). Full contract
detail lives in `agent_docs/contract.md`.

Target games: **Pokémon Emerald** (BizHawk, first) → **TEVI** (Unity, second) →
**Pseudoregalia** (UE5, third). See `agent_docs/architecture.md`'s decision log for why
TEVI replaced the brief's original Ori: Will of the Wisps pick.

## Non-goals for early work

- No shared gameplay state, physics, or collision synchronization.
- No game-specific rendering logic inside the core.
- No adapter transport or socket handling — adapters speak only to the local bridge.
- No production binary encoding or performance optimization before the contract is stable.
- No second-game adapter until Phase 5 validates the template.
- No relay authentication work before Phase 4 ships on no-auth (see `architecture.md` ADR);
  don't build room codes early just because they're the eventual goal.

## Current status

Phase 0 is **not** complete — the packet schema and adapter interface are documented in
`agent_docs/contract.md`, but several of its open questions (Emerald's exact `area_id`
encoding, the first `anim` tag set, snapshot rate) are unanswered until Phase 1 runs against
a real emulator. See `agent_docs/status.md` for the current one-line focus.

## Roadmap

### Phase 0 — Contract on paper

Visible outcome: documented schema and interface, plus an empty `agent_docs/verified.md`.
**Status: mostly done, not complete.** The contract structure (schema, message types,
adapter interface, transport, tick model) is written in `agent_docs/contract.md`. What
remains is genuinely Emerald-specific and can only be closed by Phase 1 work — see that
file's "Open questions" section.

### Phase 1 — Emerald read-only verification

Visible outcome: BizHawk Lua prints local player state from actual game memory, and it
tracks known-direction motion. Live task list: `agent_docs/phases/phase1.md`.

### Phase 2 — Fake ghost, no network

Visible outcome: a rendered ghost overlay in Emerald following a hardcoded offset, using
`gui.drawImage`. Proves the screen-position math (map coords + camera scroll) before network
code is in the picture. Gets its own `phases/phase2.md` when Phase 1 closes.

### Phase 3 — Loopback

Visible outcome: one client sends its own state through a local relay and renders its ghost
trailing itself by ~200ms. Exercises the bridge, the relay protocol, the schema, and the
interpolation buffer on one machine before a second machine is involved. Implements the
payload/rate limits from `agent_docs/contract.md` even though no-auth means nothing else
guards the relay yet.

### Phase 4 — Two players

Visible outcome: two BizHawk clients render each other's ghosts and handle joins/drops.
First real multiplayer milestone. No-auth per the current ADR — treat the relay address as
something only shared directly with a friend, not something safe to post publicly, until
room codes ship (see below).

### Phase 5 — Extract the template

Visible outcome: the core runs independently of the Emerald adapter against a fake adapter
that moves a ghost in a circle, with no game attached. If it doesn't run cleanly, something
leaked — check for `if game ==`-style branches in `internal/core` and `internal/relay`.
Freeze `adapters/_template/` as the reusable adapter stub — this is the real deliverable of
this phase, not the Emerald adapter itself.

### Phase 6 — Second game (TEVI)

Visible outcome: repeat phases 1–4 for TEVI using the frozen template, and find out whether
the contract holds up outside Emerald. First task is verifying TEVI's IL2CPP vs Mono status
— unconfirmed, do not assume.

### Post-Phase-4 — Room codes

Not a numbered phase because it doesn't gate the games-side milestones. Add shared-secret
room codes to the relay so a session isn't just a bare IP:port. Scheduled after Phase 4
proves the two-player path works at all.

## Links

- `agent_docs/contract.md` — packet schema, adapter interface, transport, tick model.
- `agent_docs/brief.md` — original design brief and rationale.
- `agent_docs/architecture.md` — system shape and the decision log (ADRs).
- `agent_docs/phases/phase1.md` — the only currently-live phase file.
- `agent_docs/risks.md` — assumptions and risk register.
- `agent_docs/status.md` — current active phase and focus.
- `agent_docs/verified.md` — append-only verification log.
- `agent_docs/licensing.md` — third-party license audit.
