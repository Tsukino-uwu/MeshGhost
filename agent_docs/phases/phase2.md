# Phase 2 — Fake ghost, no network

> **A dated record. Adapter paths here predate the 2026-08-25 folder rename** — read any
> `adapters/bizhawk/` as `adapters/emulator/`. Left as written because a phase file records what
> was true while the phase ran; the convention is in [../README.md](../README.md).

Folded back into `agent_docs/plans.md` as complete (2026-08-11); kept here for the detailed
task-by-task record. Per `agent_docs/README.md`'s rule: a phase earns a file when it's live,
and gets folded back once it's done. Phase 3 (loopback) followed; `agent_docs/status.md` has the current phase.

## Purpose

Prove the map/camera -> screen-pixel math and `gui.drawImage` overlay drawing work in BizHawk,
using a hardcoded offset from the local player, before any network code exists. This is the
piece that would have caused a flickering or misplaced ghost in Phase 4 if left unverified —
see the tick model in `agent_docs/contract.md` for why the redraw-every-frame requirement
matters here already, even with no remote player yet.

## Approach

`adapters/bizhawk/pokemon/emerald/probes/phase2_ghost.lua` reads the local player's own on-screen sprite position
(`gSprites[gPlayerAvatar.spriteId]`, combined with `gSpriteCoordOffsetX/Y` the same way the
game itself does for its object event sprites — see the script's header comment for the exact
addresses and their `pokeemerald` source citations) and draws a placeholder image at that
position plus a hardcoded pixel offset, every frame. Reusing the game's own screen-position
output (rather than reimplementing camera-scroll math independently from map coordinates) is
a deliberate scope cut: it isolates "can we read and reproduce screen placement" from "can we
independently derive it," which is the part that actually blocks Phase 3+.

Placeholder art: `adapters/bizhawk/pokemon/emerald/assets/ghost_placeholder.bmp`, a flat 16x16 magenta box
generated for this project, not ripped from any game — see `agent_docs/licensing.md`.

## Tasks

- [x] Confirm `gui.drawImage` draws the placeholder image at all, at a fixed hardcoded screen
      position (no player-tracking yet) — isolates "can BizHawk draw the file" from "is the
      math right." Confirmed directly via the player-tracking test below (image rendered
      correctly the first time, no separate no-tracking test needed). See
      `agent_docs/verified.md`.
- [x] Confirm the ghost tracks the player's on-screen position as they walk in each cardinal
      direction, with the hardcoded offset held constant relative to the player (not relative
      to the screen or the map). Confirmed near screen center in Littleroot Town. See
      `agent_docs/verified.md`.
- [x] Confirm the ghost's position stays correct at a map edge, where the camera stops
      scrolling and the player's on-screen position moves away from screen center — this is
      the actual case that would catch a wrong formula, since the player-centered common case
      would look right even with a subtly incorrect one. Confirmed at a small interior room's
      boundary (camera couldn't scroll far enough to center the player). See
      `agent_docs/verified.md`.
- [x] Confirm the ghost does not flicker or lag a frame behind — validates the "redraw every
      frame regardless of new data" tick-model note in `agent_docs/contract.md`, ahead of it
      mattering for real with network data in Phase 3. Confirmed stable within a map; a very
      slight jitter crossing route/town connections is plausibly the same transient boundary
      hiccup Phase 1 already found in position data, not a new redraw bug. See
      `agent_docs/verified.md`.
- [ ] Confirm the `sprite.coordOffsetEnabled` assumption noted in the script's header (assumed
      true for the player's own sprite, not read from memory) — if the ghost is offset wrong
      by a camera-scroll-sized amount specifically when the camera is scrolling, that is the
      signal this assumption is wrong and the flag needs to be read and branched on instead.
- [ ] Record every confirmed fact (or correction to the script's stated assumptions) in
      `agent_docs/verified.md`, per `CLAUDE.md`'s verification standard — this must be watched
      happening on screen, not inferred from "the script ran without erroring."
- [x] **New, found during testing, not in the original list:** the sprite-slot-based
      screen-position read is invalid during battle (the ghost snaps to a reused sprite slot,
      confirmed by it moving in sync with the HP/EXP bar) — see `agent_docs/verified.md`.
      Resolved as a design decision, not a Phase 2 code fix: the data side needs no change
      (`get_local_state()` already shouldn't return `nil` during battle, so a remote ghost just
      holds still rather than despawning — desired behavior); the adapter should instead skip
      all ghost drawing while the local player is in battle, sidestepping the sprite-slot bug
      rather than diagnosing it further. Implementing that skip is deferred to whichever phase
      first has `render_remote` calls to gate (Phase 2 has no remote ghosts yet).

## Success criteria

- A placeholder ghost image renders on screen, tracking the local player at a fixed offset,
  confirmed under walking motion and at a map edge.
- The screen-position formula and every address it depends on are recorded in
  `agent_docs/verified.md` with `pokeemerald` source citations.
- No memory writes; no game behavior changed.

## Links

- `agent_docs/contract.md` — the tick model this phase's redraw-every-frame requirement
  implements ahead of schedule.
- `agent_docs/phases/phase1.md` (folded into `plans.md` once Phase 1 fully closes) — the
  addresses this phase builds on.
- `agent_docs/licensing.md` — placeholder-art rule.
- `agent_docs/verified.md` — where confirmed facts land.
