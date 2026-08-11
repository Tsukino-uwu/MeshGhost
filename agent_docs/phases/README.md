# phases — phase-based documentation

This folder contains planning and execution notes for individual project phases.

## Files

- `phase0.md` — Phase 0 contract and planning checklist.
- `phase1.md` — Phase 1 Emerald read-only verification.
- `phase2.md` — Phase 2 fake ghost, no network.
- `phase3.md` — Phase 3 loopback network validation.
- `phase4.md` — Phase 4 two-player multiplayer validation.
- `phase5.md` — Phase 5 reusable core template extraction.
- `phase6.md` — Phase 6 second game adapter validation.

## Purpose

Each phase file should document:

- what the phase is trying to achieve
- why the phase exists
- the exact success criteria
- the work breakdown and task list
- any architecture or implementation notes needed for later phases

## Phase file structure

A good phase file should include:

- A short summary of the phase goal
- Purpose and context
- Success criteria or definition of done
- A task checklist or backlog
- Risks, assumptions, and open questions
- Relevant links to related docs

## How to add a new phase

1. Create `phaseN.md` where `N` is the next phase number.
2. Add the same structure as `phase0.md` for consistency.
3. Update `agent_docs/plans.md` or other relevant docs to reference it.
