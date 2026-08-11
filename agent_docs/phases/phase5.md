# Phase 5 — Extract the template

This file captures Phase 5 planning, verification, and progress for extracting the reusable core template.

## Purpose

Phase 5 separates the game-specific Emerald code from the reusable core logic and verifies the adapter contract with a fake adapter.

This phase proves the architecture is portable and that the core has no game-specific leaks.

## Current status

- [ ] Phase 5 planning complete.
- [ ] Core extraction approach defined.
- [ ] Ready to build a fake adapter stub.

## Tasks

- [ ] Separate core logic from Emerald-specific implementation.
- [ ] Implement a fake adapter that moves a ghost in a circle.
- [ ] Confirm the core runs against the fake adapter with no game attached.
- [ ] Verify there are no `if game == "emerald"` or similar leaks in the core.
- [ ] Document the adapter stub and the reusable contract.
- [ ] Freeze the adapter interface as the reusable template.

## Success criteria

- The core runs with a fake adapter stub.
- The core contains no game-specific branches.
- The adapter contract is validated as reusable.
- The extracted template is documented for future game adapters.
