# Testing and validation

This file captures testing strategy, validation criteria, and the current verification work for MeshGhost.

## Purpose

Use `agent_docs/testing.md` to describe how the project is validated, what is being verified right now, and how future phases should be tested.

This is not the place for implementation details. It is the place for:

- validation criteria for each phase
- test cases and acceptance checks
- current verification tasks and results
- assumptions and failure modes
- references to phase planning docs and verified facts

## Current work

The current active work is Phase 0 and early Phase 1 validation.

See `agent_docs/phases/phase0.md` for the detailed checklist and backlog.

### Phase 0 testing focus

- Confirm the packet schema and adapter contract are documented and stable.
- Confirm the transport abstraction is defined and decoupled from game logic.
- Confirm `agent_docs/verified.md` exists and the verification rules are written.
- Confirm the project has a clean internal doc structure for future work.

### Phase 1 testing focus

- Verify local player state can be read from Pokémon Emerald.
- Verify the values change correctly for known-direction movement.
- Record confirmed addresses and sources in `agent_docs/verified.md`.
- Define the first observable verification steps for adapter behavior.

## Validation rules

- Every testable claim must be tied to an observed behavior.
- Every confirmed fact must be recorded in `agent_docs/verified.md`.
- Use known-direction motion or other deterministic input to validate extracted values.
- Prefer visual confirmation and raw-value logging over inferred correctness.

## Links

- `agent_docs/phases/phase0.md` — Phase 0 contract, checklist, and Emerald backlog.
- `agent_docs/verified.md` — append-only verification log.
