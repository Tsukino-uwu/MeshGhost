# Phase 2 — Fake ghost, no network

This file captures Phase 2 planning, verification, and progress for Emerald ghost rendering without network involvement.

## Purpose

Phase 2 validates the rendering and coordinate math required to display a ghost overlay in BizHawk.

This phase keeps the work offline and isolated from networking while proving the key visual path.

## Current status

- [ ] Phase 2 planning complete.
- [ ] Fake ghost rendering approach decided.
- [ ] Ready to implement overlay rendering with hardcoded state.

## Tasks

- [ ] Compute screen position from Emerald map coordinates and camera scroll.
- [ ] Create a simple ghost overlay using `gui.drawImage` or similar.
- [ ] Render a hardcoded ghost state at a fixed offset.
- [ ] Verify the overlay stays correctly aligned with the player and camera.
- [ ] Log raw coordinate values and camera offsets for debugging.
- [ ] Document rendering assumptions and any display limitations.

## Success criteria

- A ghost placeholder renders in the correct screen location relative to the player.
- The overlay behaves correctly as the player moves and the camera scrolls.
- The rendering path is validated without any network data.
- The results are documented for the later adapter implementation.
