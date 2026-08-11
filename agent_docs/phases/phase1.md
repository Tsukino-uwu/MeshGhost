# Phase 1 — Emerald read-only verification

The only phase with its own file right now, because it's the one being executed. Per
`agent_docs/README.md`'s rule: a phase earns a file when it's live, and gets folded back into
`agent_docs/plans.md` once it's done.

## Purpose

Prove BizHawk can read Emerald's local player state — position, area, and (if available)
animation — without changing game behavior, and that those values track known-direction
motion. This closes the open questions left in `agent_docs/contract.md`.

## Status

Not started. Nothing in this phase is checked off, and nothing should be until it's been
watched happening on screen — no self-certifying "planning complete" ticks. See the
verification standard in `CLAUDE.md`.

## Tasks

- [ ] Identify the local player X/Y address(es) in Pokémon Emerald, sourced from the
      `pokeemerald` decompilation (cite the exact file/symbol — see `agent_docs/licensing.md`
      for what "consulting" the decomp does and doesn't permit).
- [ ] Identify the current map bank/number address(es), same sourcing rule.
- [ ] Print those values in the BizHawk Lua console.
- [ ] Walk in each cardinal direction; confirm the values change in the expected direction
      (not just "a number changed" — the brief's "test against known-direction motion" rule).
- [ ] Check idle/walking/running if a distinct value is available for them.
- [ ] Check the same values in a second map to confirm `area_id` stability across areas.
- [ ] Note any state where these values are invalid or meaningless (menus, cutscenes, debug
      screens) — this feeds `get_local_state()`'s "return `nil`" case.
- [ ] Decide the Emerald `area_id` encoding (bank+number, concatenated how) and record the
      decision in `agent_docs/contract.md`'s open-questions list, closing that item.
- [ ] Decide the first Emerald `anim` tag set and record it the same way.
- [ ] Record every confirmed address, with its `pokeemerald` source file, in
      `agent_docs/verified.md` — only after the user has watched it work.

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
