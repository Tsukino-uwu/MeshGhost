# Risks and assumptions

This file captures known risks, assumptions, and uncertainties for MeshGhost.

## Purpose

Use this file to document the assumptions the project is making, the things that could invalidate those assumptions, and the risks that should be monitored or mitigated.

## Current assumptions

- The core/adapter/relay split is the right long-term architecture.
- A replayable JSON snapshot schema is sufficient for the first two target games.
- Pokémon Emerald can expose local player position, area, and basic animation state from BizHawk.
- Lua overlay rendering is the fastest practical approach for Emerald ghost drawing.
- The project should prioritize visibility and debugging over raw bandwidth efficiency.

## Known risks

- Changing adapter contracts after Phase 5 may create compatibility issues.
- The Unity and UE5 targets may require substantially different adapter behavior.
- BizHawk Lua may be slower or more limited than expected for real-time ghost rendering.
- Relying on a single emulator version or toolchain may create setup drift.
- Undocumented game state or menu/camera edge cases can break ghost placement.

## Mitigations

- Keep the contract minimal, and validate it early with a fake adapter.
- Record confirmed facts in `agent_docs/verified.md` and treat assumptions as provisional.
- Keep transport abstract and swap-friendly so the relay layer can evolve.
- Use phase-based validation to catch contract or rendering issues early.
- Track toolchain versions in `agent_docs/environment.md`.
