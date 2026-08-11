# agent_docs — internal project documentation

This folder contains internal documentation for MeshGhost. It is intended for developers and collaborators who are working on architecture, planning, testing, and implementation details.

## Files

- `architecture.md` — system architecture and non-obvious design rules.
- `plans.md` — live roadmap, planning notes, and feature backlog.
- `bug.md` — bug-tracking notes and investigation history.
- `bug-fixes.md` — resolved bug notes and corrective actions.
- `environment.md` — environment, toolchain, and workspace setup notes.
- `testing.md` — testing strategy, validation criteria, and test cases.
- `non-goals.md` — explicit scope boundaries and intentional exclusions.
- `review-checklist.md` — prompts and review guidance for model-validated docs.
- `risks.md` — project assumptions and risk register.
- `architecture-decisions.md` — recorded rationale for major architecture choices.
- `status.md` — the active phase and current project focus.
- `glossary.md` — definitions of project-specific terms.
- `phases/` — phase-based planning documents for incremental work.

## How to use this folder

- Keep high-level decision rationale in `architecture.md`.
- Keep active work plans and milestones in `plans.md`.
- Keep confirmed implementation facts in `agent_docs/verified.md`.
- Create phase-specific planning docs inside `phases/` when a phase has enough content to justify its own file.
- Use `phases/README.md` as the launch point for phase documents.

## Document categories

- `README.md` (repo root) is the public landing page.
- `agent_docs/README.md` is the internal docs index and guide.
- `architecture.md` is for non-obvious design decisions and system rules.
- `plans.md` is for current priorities, roadmaps, and live planning.
- `phases/` is for phase-specific execution and checkpoint documentation.
- `agent_docs/verified.md` is for confirmed runtime facts and references.
- `testing.md` is for validation, test plans, and acceptance criteria.
- `non-goals.md` is for explicit scope boundaries and intentional exclusions.
- `review-checklist.md` is for model review prompts and doc validation.
- `risks.md` is for project assumptions and risk tracking.
- `architecture-decisions.md` is for major architectural rationale.
- `status.md` is for the current active work state.
- `bug.md` and `bug-fixes.md` are for tracking investigations and closures.

## Document structure and style

- Use clear headings and short sections.
- Include "why", "what", and "how" for any implementation-oriented notes.
- Keep each file focused on one audience: public readers, planners, implementers, or verifiers.
- Prefer links over repetition: cross-reference related docs instead of copying large content.
- Use append-only files for verified facts and confirmed decisions.
- Add a small index or summary when a folder contains more than one doc.

## When to create a new file

- Create a new file when the content is phase-specific, long, or likely to change independently.
- Keep short notes in the existing file when they are directly related to the current roadmap.
- Use `phases/` for multi-step plans that deserve their own lifecycle history.
