# Phase 4 — Two players

This file captures Phase 4 planning, verification, and progress for two-player ghost rendering.

## Purpose

Phase 4 validates that two separate clients can exchange state and render each other's ghosts.

This phase is the first real multiplayer milestone and proves joins, drops, and area mismatch handling.

## Current status

- [ ] Phase 4 planning complete.
- [ ] Second-client connection plan defined.
- [ ] Ready to connect two BizHawk instances.

## Tasks

- [ ] Launch a second BizHawk instance and connect it to the relay.
- [ ] Send and receive remote snapshots between clients.
- [ ] Render the remote ghost on each client.
- [ ] Handle player joins and drops cleanly.
- [ ] Handle `area_id` mismatches by not rendering ghosts in other maps.
- [ ] Confirm remote motion visually and that ghosts update correctly.
- [ ] Document multiplayer assumptions and failure cases.

## Success criteria

- Two clients exchange state and render each other's ghosts.
- Joins and disconnects are handled gracefully.
- Remote ghosts are not rendered across different `area_id` values.
- The multiplayer validation is documented for the core/adapter split.
