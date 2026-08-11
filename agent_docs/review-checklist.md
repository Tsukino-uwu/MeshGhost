# Review checklist

This file captures prompts and review guidance for validating MeshGhost docs and planning with stronger models such as Claude or Opus5.

## Purpose

Use this file to create a repeatable review process for internal docs, architecture decisions, and phase plans. It is especially useful when asking a stronger model to review project scope, risk, and contract design.

## Model review checklist

- Is the packet schema complete and clear for the first two games?
- Does the adapter contract keep game-specific details out of the core?
- Are `area_id` and `anim` treated consistently as opaque values in the core?
- Is the transport abstraction sufficiently decoupled from both core and adapters?
- Are the Phase 0–6 goals and success criteria precise and realistic?
- Does the non-goals list capture the intended scope boundaries for early work?
- Are the assumptions in `risks.md` specific enough to validate with Emerald?
- Is the onboarding guidance in `environment.md` sufficient to reproduce verification steps?
- Are there any missing edge cases in the Phase 1 verification plan?
- Does the project documentation make it easy to hand off to another contributor?

## Review prompt template

Use this prompt when asking a stronger model to review the project docs:

> Please review the MeshGhost internal documentation and roadmap. Evaluate whether the packet schema, adapter contract, transport abstraction, phase goals, acceptance criteria, and non-goals are clear, consistent, and sufficient for Phase 0 through Phase 4. Highlight any missing assumptions, risks, or edge cases, and suggest improvements that would make the project easier to implement and verify.

## Files for full review

Ask Opus5 to review the following files as a group, or use this list if you want it to verify “all files” later:

- `README.md`
- `Ghostsync brief.md`
- `agent_docs/README.md`
- `agent_docs/plans.md`
- `agent_docs/phases/README.md`
- `agent_docs/phases/phase0.md`
- `agent_docs/phases/phase1.md`
- `agent_docs/phases/phase2.md`
- `agent_docs/phases/phase3.md`
- `agent_docs/phases/phase4.md`
- `agent_docs/phases/phase5.md`
- `agent_docs/phases/phase6.md`
- `agent_docs/non-goals.md`
- `agent_docs/review-checklist.md`
- `agent_docs/risks.md`
- `agent_docs/architecture-decisions.md`
- `agent_docs/environment.md`
- `agent_docs/status.md`
- `agent_docs/verified.md`
- `agent_docs/testing.md`
- `agent_docs/glossary.md`
- `agent_docs/bug.md`
- `agent_docs/bug-fixes.md`

If you want Opus5 to do an “all files” check later, point it at this list and say “validate these files together, then suggest any corrections or missing docs.”

## Reviewer guidance

- Prefer concrete comments over generic praise.
- Call out any inconsistent terminology or vague sections.
- Suggest one specific improvement per major doc area.
- Do not rewrite the entire roadmap; focus on gaps and clarifications.
