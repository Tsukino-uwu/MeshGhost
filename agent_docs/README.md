# agent_docs — internal project documentation

Internal documentation for MeshGhost: architecture, planning, licensing, and verification.

## Files

- `brief.md` — the original design brief: vision, non-goals, prior art, rationale.
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
- `phases/` — a file per phase, but **only for the phase currently being executed.** Fold a
  phase's content back into `plans.md` once it's done rather than leaving a stale file.

## How to use this folder

- `contract.md` is the first thing to read before touching `internal/core`, `internal/relay`,
  or any adapter.
- Keep confirmed implementation facts in `verified.md` — nowhere else, and never before the
  user has watched them work.
- Create `phases/phaseN.md` when phase N starts; fold it into `plans.md` when phase N ends.

## Document structure and style

- Use clear headings and short sections.
- Prefer links over repetition — cross-reference instead of copying content between files.
- Keep each file focused on one audience: public readers (`README.md` at repo root),
  planners (`plans.md`, `status.md`), implementers (`contract.md`, `architecture.md`), or
  verifiers (`verified.md`, `licensing.md`).
