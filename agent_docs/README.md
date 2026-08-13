# agent_docs — internal project documentation

Internal documentation for MeshGhost: architecture, planning, licensing, and verification.

## Files

- `brief.md` — the original design brief: vision, non-goals, prior art, rationale.
- `project-history.md` — retrospective on the pre-planning phase before any adapter existed.
  Per-adapter build stories live in each game's own `README.md` instead.
- `contract.md` — **the durable artifact.** Packet schema, message types, adapter interface,
  transport, tick model, limits. Changes here are contract revisions, not routine edits —
  record the "why" in `architecture.md`'s decision log.
- `architecture.md` — system shape and the architecture decision log (ADRs).
- `plans.md` — live roadmap, phase status, non-goals.
- `status.md` — one-screen summary of the active phase and current focus.
- `risks.md` — assumptions and risk register.
- `licensing.md` — third-party license audit. Check before referencing any outside project.
- `environment.md` — toolchain and environment notes, filled in as phases actually run.
- `verified.md` — append-only, human-gated log of confirmed runtime facts.
- `pitfalls.md` — adapter-specific issues across all games: symptom, how it was diagnosed,
  root cause, fix. Not design decisions (`risks.md`) or confirmed facts (`verified.md`).
- `phases/` — a file per phase. Kept around after the phase ends as a work log/archive
  rather than folded away — `status.md` and `plans.md` stay the current-state summary.

## How to use this folder

- `contract.md` is the first thing to read before touching `internal/core`, `internal/relay`,
  or any adapter.
- Keep confirmed implementation facts in `verified.md` — nowhere else, and never before the
  user has watched them work.
- Create `phases/phaseN.md` when phase N starts; leave it in place as a historical record
  once phase N ends (update `plans.md`/`status.md` to reflect current state, don't delete it).

## Document structure and style

- Use clear headings and short sections.
- Prefer links over repetition — cross-reference instead of copying content between files.
- Keep each file focused on one audience: public readers (`README.md` at repo root),
  planners (`plans.md`, `status.md`), implementers (`contract.md`, `architecture.md`), or
  verifiers (`verified.md`, `licensing.md`).
