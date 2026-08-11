# Phase 3 — Loopback

This file captures Phase 3 planning, verification, and progress for local relay loopback testing.

## Purpose

Phase 3 validates the network/transport path by sending local state through a relay and receiving it back on the same client.

This phase exercises the schema, buffering, and receive path while remaining on one machine.

## Current status

- [ ] Phase 3 planning complete.
- [ ] Local relay design is defined.
- [ ] Ready to implement loopback transport and echo logic.

## Tasks

- [ ] Implement a local relay server or local transport loopback.
- [ ] Serialize local snapshots using the phase 0 packet schema.
- [ ] Send the snapshot through the transport and receive it back.
- [ ] Render the returned state as a ghost with a visible latency.
- [ ] Confirm the ghost trails the player by ~200ms.
- [ ] Validate ordering and timestamp handling.
- [ ] Document the transport invariants and loopback behavior.

## Success criteria

- The client can send its own state and receive it back via the relay.
- A ghost renders using the looped-back data.
- The schema and transport layer are validated in a runnable on-machine test.
- The loopback path is documented for later multi-client extension.
