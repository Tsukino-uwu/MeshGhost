# Glossary

This file defines project-specific terms used in MeshGhost documentation.

## Terms

- `core` — the game-agnostic client logic that handles snapshots, interpolation, and communication.
- `adapter` — the game-specific boundary layer that reads local game state and renders remote ghosts.
- `relay server` — the network component that forwards snapshots between clients.
- `packet schema` — the format used to serialize and exchange state snapshots.
- `snapshot` — a single sample of game state that includes position, area, animation tag, and metadata.
- `area_id` — an opaque string representing the current game area or scene.
- `anim` — an opaque animation/state tag used for remote ghost rendering.
- `extras` — a free-form dictionary for game-specific data that does not fit the core schema.
- `agent_docs/verified.md` — the append-only file that records confirmed runtime facts and sources.
- `phase` — a discrete milestone or step in the project plan.
- `loopback` — a test mode where a client sends data through the transport and receives it back locally.

## Guidance

- Use these terms consistently in docs and comments.
- Add new terms here when a concept appears frequently in planning or implementation notes.
