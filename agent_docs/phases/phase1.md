# Phase 1 — Emerald read-only verification

Folded back into `agent_docs/plans.md` as complete (2026-08-11); kept here for the detailed
task-by-task record. Per `agent_docs/README.md`'s rule: a phase earns a file when it's live,
and gets folded back once it's done. Phase 2 followed this one; `agent_docs/status.md` has the current phase — see
`agent_docs/phases/phase2.md`.

## Purpose

Prove BizHawk can read Emerald's local player state — position, area, and (if available)
animation — without changing game behavior, and that those values track known-direction
motion. This closes the open questions left in `agent_docs/contract.md`.

## Status

Core task list complete (2026-08-11) — every item watched happening on screen per
`CLAUDE.md`'s verification standard, all recorded in `agent_docs/verified.md`, and both
`contract.md` decisions made from that evidence. The optional Archipelago-coexistence
checklist is also complete (2026-08-11, with the real `connector_bizhawk_generic.lua`) — see
`agent_docs/verified.md`; it surfaced a real finding (the AP patch invalidates the fixed
`gPlayerAvatar`/`gObjectEvents` addresses, though not the `gSaveBlock1Ptr`-relative
position/map reads) that any future adapter work targeting Archipelago coexistence needs to
account for. Only remaining: bike/surf flags (deferred, far into the game, not blocking).

## Tasks

- [x] Identify the local player X/Y address(es) in Pokémon Emerald, sourced from the
      `pokeemerald` decompilation (cite the exact file/symbol — see `agent_docs/licensing.md`
      for what "consulting" the decomp does and doesn't permit). See `agent_docs/verified.md`.
- [x] Identify the current map bank/number address(es), same sourcing rule. See
      `agent_docs/verified.md`.
- [x] Print those values in the BizHawk Lua console. `adapters/pokemon/emerald/phase1_probe.lua`.
- [x] Walk in each cardinal direction; confirm the values change in the expected direction
      (not just "a number changed" — the brief's "test against known-direction motion" rule).
      Confirmed and reproduced twice; see `agent_docs/verified.md`.
- [x] Check idle/walking/running if a distinct value is available for them. `runningState`
      confirmed: 0=idle, 1=turning, 2=moving (walk or run). Dash flag (`flags` bit 7,
      running shoes) confirmed: set while running, clear while walking/idle. Bike/surf flags
      not tested — far into the game, deferred. See `agent_docs/verified.md`.
- [x] Check the same values in a second map to confirm `area_id` stability across areas.
      Confirmed on transition outdoors→indoors: mapGroup/mapNum changed 0,9 → 1,0 and held
      steady after. See `agent_docs/verified.md`.
- [x] Note any state where these values are invalid or meaningless (menus, cutscenes, debug
      screens) — this feeds `get_local_state()`'s "return `nil`" case. Confirmed NOT invalid
      during: pause menu, bag, options, player profile, NPC dialogue, forced-movement
      cutscenes, cutscene-driven warps/teleports, wild battle, and trainer battle (see
      `agent_docs/verified.md`). A single-frame transient placeholder read WAS observed on
      some (not all) transitions, right when `gSaveBlock1Ptr` relocates — decided in
      `agent_docs/contract.md`: this warrants an adapter-side one-frame debounce around a
      `mapGroup`/`mapNum` change, not a `nil` return. `nil` itself is only warranted when
      `gSaveBlock1Ptr` is null (no save loaded).
- [x] Decide the Emerald `area_id` encoding (bank+number, concatenated how) and record the
      decision in `agent_docs/contract.md`'s open-questions list, closing that item.
      `"{mapGroup}:{mapNum}"`, e.g. `"0:9"`.
- [x] Decide the first Emerald `anim` tag set and record it the same way. `idle`/`walking`/
      `running`, driven by `runningState`/`dash`; facing carried separately via `orientation`.
- [x] Record every confirmed address, with its `pokeemerald` source file, in
      `agent_docs/verified.md` — only after the user has watched it work.

### Archipelago coexistence

Optional, but same setup effort as the tasks above — see the depth ladder in
`agent_docs/plans.md` and `agent_docs/risks.md` for why this matters before any Tier 3 work.

- [x] Confirm whether BizHawk can run two Lua scripts at once — Archipelago's
      `connector_bizhawk_generic.lua` and a MeshGhost read-only script loaded together in the
      same Lua Console. This is the single biggest coexistence risk; check it first. Confirmed
      with the real connector (not just placeholder scripts) — see `agent_docs/verified.md`.
- [x] Re-check the confirmed player X/Y and map addresses above against an
      Archipelago-patched `.gba` (produced by the ArchipelagoLauncher from an `.apemerald`
      patch file), not just a vanilla ROM — confirm whether the patch shifts them. Position/map
      (`gSaveBlock1Ptr`-relative) confirmed NOT shifted. `gPlayerAvatar`/`gObjectEvents` (fixed
      addresses) confirmed shifted or invalidated — read all-ones garbage that didn't track
      real dash/runningState/facing changes. See `agent_docs/verified.md`.
- [x] Note any visible performance difference running both scripts at once vs. MeshGhost
      alone. User reported 0 noticeable difference. See `agent_docs/verified.md`.
- [x] Record results in `agent_docs/verified.md` regardless of outcome — "the patch does not
      move these addresses" is as much a confirmed fact as "the patch moves them by N bytes."

## Success criteria

- Local player position is confirmed from real Emerald runtime memory, not inferred.
- Current map/area is confirmed and expressible as a stable `area_id`.
- Values are shown to change correctly under known-direction motion.
- Every confirmed fact is in `agent_docs/verified.md` with its source.
- The relevant open questions in `agent_docs/contract.md` are closed.

## Links

- `agent_docs/contract.md` — the schema fields this phase is populating.
- `agent_docs/environment.md` — BizHawk/Lua setup this phase depends on.
- `agent_docs/verified.md` — where confirmed facts land.
- `agent_docs/licensing.md` — the rule on using `pokeemerald` as a reference.
