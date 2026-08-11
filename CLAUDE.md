# Working notes for Claude

placeholder text
read "Ghostsync brief.md" for an explanation of what I want this project to be
lets discuss/plan it out a bit more as well, but the brief should cover the main idea

## This file is capped at 300 lines

**Treat the cap as a rule, not a target.**

**Research cited by the humanlayer guide puts frontier thinking models at ~150–200 followable
instructions, and finds degradation is **uniform, not tail-first**. More instructions doesn't mean the bottom of the file gets ignored; it means *every* rule above gets followed slightly worse, including the ones that exist because
something went wrong once.

**So when this file would exceed 300 lines, something moves to `agent_docs/` — the question is
never "can I add this?" but "what comes out to make room?"** Adding a rule is nearly always
right; adding an explanation of a rule usually isn't. If a rule needs a paragraph of reasoning,
the rule stays here and the reasoning goes to a .md file in `agent_docs/`.

## Internal docs conventions

- `README.md` is the public repo landing page.
- `agent_docs/README.md` is the internal documentation index.
- `agent_docs/architecture.md` is for architecture and design rules.
- `agent_docs/plans.md` is for live roadmaps and active planning.
- `agent_docs/phases/` is for phase-specific execution docs like `phase0.md`.
- `agent_docs/verified.md` is the append-only log for confirmed runtime facts.

Use this file only for working notes and rules that must be immediately visible to the agent. Put longer design rationale, contract definitions, and phase planning into `agent_docs/`.
