# agent_docs — internal project documentation

Internal documentation for MeshGhost: architecture, planning, licensing, and verification.

## Files

- [brief.md](brief.md) — the original design brief: vision, non-goals, prior art, rationale.
- [project-history.md](project-history.md) — retrospective on the pre-planning phase before any
  adapter existed. Per-adapter build stories live in each game's own `README.md` instead.
- [contract.md](contract.md) — **the durable artifact.** Packet schema, message types, adapter
  interface, transport, tick model, limits. Changes here are contract revisions, not routine
  edits — record the "why" in [architecture.md](architecture.md)'s decision log.
- [architecture.md](architecture.md) — system shape and the architecture decision log (ADRs).
- [plans.md](plans.md) — live roadmap, phase status, non-goals.
- [ideas.md](ideas.md) — unscheduled feature backlog. Not the roadmap — researched enough to
  act on when picked, but nothing here is committed until it moves into [plans.md](plans.md).
- [status.md](status.md) — one-screen summary of the active phase and current focus.
- [risks.md](risks.md) — assumptions and risk register.
- [licensing.md](licensing.md) — third-party license audit. Check before referencing any
  outside project.
- [environment.md](environment.md) — toolchain and environment notes, filled in as phases
  actually run.
- [verified.md](verified.md) — append-only, human-gated log of confirmed runtime facts.
- [pitfalls.md](pitfalls.md) — adapter-specific issues across all games: symptom, how it was
  diagnosed, root cause, fix. Not design decisions ([risks.md](risks.md)) or confirmed facts
  ([verified.md](verified.md)).
- `phases/` — a file per phase. Kept around after the phase ends as a work log/archive
  rather than folded away — [status.md](status.md) and [plans.md](plans.md) stay the
  current-state summary.
- [../internal/README.md](../internal/README.md) — lives with the code, not here on purpose
  (see that file). Security and privacy posture of the Go networking layer: what's already
  checked-safe (no client ever learns a peer's IP; room-code auth, protocol- and game-version
  checks, and bounded reads all shipped 2026-08-14) versus the gaps that remain — no TLS, so a
  room code crosses the wire in plaintext.

## How to use this folder

- [contract.md](contract.md) is the first thing to read before touching `internal/core`,
  `internal/relay`, or any adapter.
- Keep confirmed implementation facts in [verified.md](verified.md) — nowhere else, and never
  before the user has watched them work.
- Create `phases/phaseN.md` when phase N starts; leave it in place as a historical record
  once phase N ends (update [plans.md](plans.md)/[status.md](status.md) to reflect current
  state, don't delete it).

## Document structure and style

- Use clear headings and short sections.
- Prefer links over repetition — cross-reference instead of copying content between files.
- Keep each file focused on one audience: public readers ([README.md](../README.md) at repo
  root), planners ([plans.md](plans.md), [status.md](status.md)), implementers
  ([contract.md](contract.md), [architecture.md](architecture.md)), or verifiers
  ([verified.md](verified.md), [licensing.md](licensing.md)).
