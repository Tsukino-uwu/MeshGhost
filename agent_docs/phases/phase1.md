# Phase 1 — Emerald read-only verification

This file captures Phase 1 planning, verification, and progress for the first target game: Pokémon Emerald.

## Purpose

Phase 1 proves the first adapter input path by verifying that BizHawk can read the required local player state from Pokémon Emerald without changing game behavior.

This phase establishes the actual values for `position`, `area_id`, and `anim`, and confirms that those values behave consistently under player motion.

## Current status

- [x] Phase 1 planning complete.
- [ ] Verification tasks defined and prioritized.
- [ ] Ready to begin BizHawk/Emerald validation.

## Assumptions

- BizHawk Lua can read Emerald player position and map state reliably.
- `area_id` can be represented as an opaque identifier such as bank+map or a unique string.
- `anim` can be expressed as a small tag set and does not need a universal vocabulary.
- `orientation` is optional and may be deferred until a real use case emerges.

## Tasks

- [ ] Identify the local player X/Y coordinates in Pokémon Emerald.
- [ ] Identify the current map/bank/area in Pokémon Emerald.
- [ ] Print those values in BizHawk Lua and confirm their runtime sources.
- [ ] Walk in cardinal directions and confirm the values change as expected.
- [ ] Verify stationary, sprinting, and idle motion states if available.
- [ ] Record confirmed addresses, offsets, and any emulator-specific notes in `agent_docs/verified.md`.
- [ ] Define the Emerald mapping for the core snapshot fields:
  - `position`
  - `area_id`
  - `anim`
  - `orientation`
  - `extras`
- [ ] Decide whether `orientation` is needed for Emerald and how it should be represented.
- [ ] Document edge cases where the player is not in a normal map (menus, cutscenes, debug screens).

## Success criteria

- The local player position is confirmed from real Emerald runtime memory.
- The current map/area is confirmed and can be expressed as a stable opaque `area_id`.
- Motion validation proves that the raw values change consistently with player movement.
- The first Emerald adapter input contract is documented and ready for Phase 2.
- All confirmed facts are recorded in `agent_docs/verified.md` with sources.

## Recommended verification steps

1. Start Emerald in BizHawk and attach a Lua script.
2. Read the player X and Y coordinates and output them in the Lua console.
3. Read the current map/bank or map ID and output it.
4. Move the player in known directions and verify the values update correctly.
5. Record the exact memory addresses or API calls used to derive each field.
6. Check the same values in a second map or area to validate `area_id` stability.
7. Note any values that are only valid in specific game modes or screens.

## Open questions

- Can `area_id` be a simple string derived from Emerald map/bank, or does it need more structure?
- Is a dedicated `orientation` field needed for Emerald ghost rendering, or can facing be encoded in `anim` or `extras`?
- Which `anim` tags are sufficient for Phase 2 visibility: `idle`, `walking`, `running`, `facing`?
- What should the adapter do when the local player is off-screen or in a non-renderable state?

## Notes

- Keep this phase focused on reading state, not rendering or network transport.
- Do not commit to a final `anim` vocabulary until the first real ghost visualization is attempted.
- Use `agent_docs/verified.md` as the single source of truth for Emerald-specific facts.
