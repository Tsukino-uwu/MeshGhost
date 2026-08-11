# Non-goals

This file documents what MeshGhost is intentionally not trying to do in the current roadmap. Making these exclusions explicit helps avoid scope creep and keeps early work focused on the core contract.

## Purpose

Use this file to record explicit non-goals, especially for Phase 0 through Phase 4. These are design boundaries the project will not cross until a later phase or until the contract is proven.

## Current non-goals

- No shared gameplay state, physics, or collision synchronization.
- No core-side game logic or engine-specific rendering.
- No adapter transport or socket handling inside game-specific code.
- No production binary wire format or low-level packet optimization before the contract is stable.
- No second-game adapter implementation until the template is extracted and proven.
- No multiplayer gameplay mechanics beyond ghost visualization.
- No automatic interpolation or prediction before the snapshot contract is validated.
- No pathfinding, AI, or remote player control.
- No emulator-specific game manipulation, memory writes, or save-state editing for production features.
- No support for transient or partial game screens unless the adapter contract specifically defines them.

## Why this matters

- It keeps the core reusable and game-agnostic.
- It ensures early work is verifiable and low-risk.
- It prevents premature complexity in the first adapter.
- It keeps the project aligned with the visual-only multiplayer goal.

## When to revisit

Review this file before starting Phase 5 or when the contract changes materially. Any item removed from the non-goals list should be accompanied by an architecture decision record in `architecture-decisions.md`.
