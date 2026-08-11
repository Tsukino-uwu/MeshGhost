# Phase 0 — Contract and planning checklist

This file captures the exact Phase 0 output: a precise packet schema, adapter contract, transport abstraction, verification requirements, and the first Emerald backlog.

## Purpose

Phase 0 is a documentation-first milestone. The goal is to lock down the boundary and invariants before any emulator hooks, network code, or game-specific implementation begins.

This is the safest and highest-leverage work to do while waiting for Claude Pro / Opus5 or before touching source code.

## Packet schema

The core and relay exchange a small snapshot object. The schema is intentionally opaque in key places.

Fields:

- `player_id` — server-assigned identifier for a connected client. Must be stable for the session.
- `seq` — monotonically increasing integer for ordering.
- `timestamp` — numeric time for interpolation. Use milliseconds relative to client start or Unix ms, but stay consistent.
- `area_id` — opaque string describing the current area. Examples: Emerald map bank/number, Unity scene name. The core may only compare equality; it must not assume semantics.
- `position` — variable-length array of floats. Example: 2 values for 2D games, 3 for 3D games. The core does not assume a fixed length.
- `orientation` — optional field. Can be a scalar, vector, quaternion, or any game-specific representation. Treated opaquely by the core.
- `anim` — opaque string tag representing animation state. The core may only compare equality and pass it through.
- `extras` — small free-form dict for game-specific metadata.

Schema invariants:

- Do not design a universal animation vocabulary.
- Do not normalize coordinate systems in the core.
- Do not branch on `area_id` or `anim` inside the core.
- Keep JSON as the default wire format until bandwidth becomes a real problem.

Example JSON snapshot:

```json
{
  "player_id": "p1",
  "seq": 123,
  "timestamp": 1690000000000,
  "area_id": "emerald-0001",
  "position": [123.0, 45.0],
  "orientation": null,
  "anim": "walking",
  "extras": {
    "facing": "left"
  }
}
```

## Adapter contract

Adapters are the thin boundary between the game and the core. The contract must remain small and stable.

Functions:

- `get_local_state()` -> `snapshot | nil`
  - Called by the core to sample the local game state.
  - Returns a snapshot object matching the packet schema, or `nil` if the local state should not be sent.

- `render_remote(id, state)` -> `void`
  - Called by the core to render or update a remote ghost.
  - `id` is the remote player identifier.
  - `state` is the snapshot object received from the network.

- `despawn_remote(id)` -> `void`
  - Called when a remote player disconnects, drops, or becomes invalid for rendering.

Contract invariants:

- The adapter may access game memory and rendering primitives.
- The adapter may not open sockets or perform network I/O.
- The core may not access game memory or rendering primitives.
- The core may not contain game-specific branches such as `if game == "emerald"`.
- Coordinate-system normalization happens inside the adapter.

## Transport abstraction

The core must be transport-agnostic. Wrap the actual network layer behind a minimal API.

Transport methods:

- `send(bytes)`
  - Sends serialized data to the relay or connected peer.
  - The core only knows it can call `send` with a bytes/string payload.

- `on_receive(callback)`
  - Registers a callback that receives incoming bytes/string data.
  - The callback should deserialize the payload and hand it back to the core.

Transport invariants:

- The adapter does not implement transport.
- The core does not implement transport details.
- The relay or local transport layer may evolve independently.
- Use JSON until there is evidence that binary encoding is needed.

## Verification requirements

This project must document confirmed facts before implementation.

- `agent_docs/verified.md` must exist before Phase 1 begins.
- Confirmed entries must include the source for every memory address, API call, hook, or game-specific fact.
- The file is append-only and only written after the user has observed the expected behavior.

Recommended verification pattern:

- Read a value.
- Walk in a known direction.
- Confirm the value changes as expected.
- Record the source and the observed behavior.

## Phase 0 checklist

- [x] Finalize the packet schema and document it.
- [x] Finalize the adapter interface and document it.
- [x] Finalize the transport abstraction and document it.
- [x] Write the invariants that separate core, adapter, and transport.
- [x] Create `agent_docs/verified.md` and set its rules.
- [x] Add this `agent_docs/phase0.md` file to the repo.
- [x] Update `agent_docs/plans.md` and `README.md` to reference Phase 0.

## Current status

- Phase 0 is complete: contract, transport, and documentation are defined.
- Internal docs structure is established with `agent_docs/README.md` and `agent_docs/phases/README.md`.
- `agent_docs/verified.md` exists and is ready for runtime confirmation entries.
- Next work: begin Phase 1 verification for Pokémon Emerald.

## Initial Emerald backlog

These are the first work items for Phase 0 and Phase 1 on Pokémon Emerald.

- [ ] Document the exact snapshot format that the Emerald adapter will produce.
- [ ] Define how `position`, `area_id`, `anim`, and `extras` map to Emerald-specific data.
- [ ] Confirm whether `orientation` is needed for Emerald, and if so, how it will be represented.
- [ ] Decide on local snapshot frequency and sequence numbering behavior.
- [ ] Define how `area_id` will represent Emerald map state (bank + number, special cases).
- [ ] Define the first `anim` tag set for Emerald, even if it is only `idle`, `walking`, `running`.
- [ ] Plan the first BizHawk verification step: print player X/Y/map and confirm movement.
- [ ] Plan the fake ghost step: draw a hardcoded overlay using `gui.drawImage`.
- [ ] Plan the loopback step: use a local relay to send and receive the same snapshot.

## Success criteria for Phase 0

- The packet schema is fully documented and accepted.
- The adapter contract is explicit and stable.
- The transport API is defined and decoupled.
- The repo contains `agent_docs/verified.md` and the Phase 0 roadmap.
- The first Emerald backlog is written and ready to implement.
