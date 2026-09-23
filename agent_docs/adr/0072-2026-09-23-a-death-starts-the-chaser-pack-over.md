# 2026-09-23 — A death starts the chaser pack over: `chaser_reset`, adapter → core

<!-- ADR 0072. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** a new bridge message, `chaser_reset`, adapter → core, **no payload**: the core
  starts the running chaser pack over exactly as at the start of play. The ghosts are dropped now,
  the history they follow is replaced, and a fresh pack appears only once the player has been
  moving for the spawn delay again. The adapter sends it where its game restarts the player; in
  Pseudoregalia that is a death, which reloads the level. **Why** it was sent is the adapter's
  per-game fact, and the core learns nothing about it.
- **Status:** built and tested 2026-09-23. Core: `ResetChasers` (`core/chaser.go`) calls
  `StartChasers`, ignores a reset while no pack runs, and ignores one landing within a second of
  the last (`chaserResetMinGap`). `TestChaserResetStartsThePackOver` fails without the handler
  (measured: *"chaser_reset did not despawn the chaser"*); `TestChaserResetIsBoundedAndNeedsAPack`.
  Pseudoregalia sends it on the local death counter's edge, latched on a confirmed send.
  **User-confirmed on screen the same night** (*"yee it works"*; `adapters/pseudoregalia/VERIFIED.md`).

## The defect

With `chaser.contact` set to `"kill"` (ADR 0068), the pack followed the player's recording through
the death, the reload and the jump to the respawn point, so the first chaser landed on a player
still standing there: five deaths in ~25 s (the adapter's log, 2026-09-23). The same replay made a
chaser run the game's death fade and stay a shadow after the respawn, reported on 2026-09-18 and
again on 2026-09-23.

## What was tried first

A 3 s respawn hold: after a death, the adapter reported `player_frozen` (ADR 0053) for 3 s, so the
pack's clock stood still and contact could not fire. It stopped the loop, and the user judged the
timing *"about right"*. The user then chose a different shape: *"if you die/respawn, chaser ghosts
should just despawn, then a bit after spawn in fresh/new again as if you just started playing"*.
A hold only delays the chasers reaching the respawn point; a reset means they never follow the
player through the death at all, which also removes the death-fade replay. The hold was removed
from the adapter in the same change.

## Why a new message, and why no payload

Only the core holds the recording the pack follows, so only the core can start it over. The
adapter knows the player died; the core does not, and must not (ADR 08-20: the core never learns
game state). A message that says "start the pack over" and nothing else passes the game-blindness
tests the way `player_frozen` does: every game with a chaser has some moment it wants a clean
pack, and the core learns nothing about which. No field means nothing for the frozen-field gate
(`internal/gameblind`) to guard.

## What it does not touch

Other players' ghosts and replay ghosts. Neither follows the local player's path. The adapter
already removes every ghost at a level load and respawns them into the new world. The recorder,
the replay ring and the wire are untouched: a reset drops the pack's own history, never a
recording.

## Costs and limits

- A reset rebuilds the pack's shared history, so it is bounded to one per second
  (`chaserResetMinGap`). A real restart of the player is seconds apart.
- An adapter that never sends it keeps today's behaviour exactly.
- Contract: `contract.md` gains a paragraph beside `player_frozen`; `bridge/bridge.go` lists the
  type; `adapters/_template/PROTOCOL.md` documents it for the next adapter.
