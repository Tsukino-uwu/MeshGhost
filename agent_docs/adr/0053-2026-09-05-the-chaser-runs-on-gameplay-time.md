# 2026-09-05 — The chaser runs on gameplay time, which stops while the player is frozen

<!-- ADR 0053. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** a new bridge message, `player_frozen`, adapter → core, pushed **on change**:
  `frozen` (bool) — the game is holding the player still and this is not gameplay (an item popup,
  the pause menu, any modal). **Its one consumer is the chaser pack.** The chaser's clock stands
  still while the flag is set and frames taken while frozen are never offered to it, so a pause
  costs the chaser no delay: it holds where it is and resumes the same distance behind. The
  recorder, the ring, replay ghosts and the wire are untouched.
- **Status:** core side built and tested 2026-09-05 (`core/chaser_test.go`,
  `TestChaserHoldsWhileThePlayerIsFrozen`, which fails without the fix). **No adapter sends it
  yet**; Pseudoregalia's signal is unmeasured (see the open half below).

## The defect

Measured 2026-09-04 with `probe_pickup/` (`adapters/pseudoregalia/UNVERIFIED.md`): an item popup
froze the pawn for 110 seconds while every field the adapter samples stayed byte-identical at
its last in-flight value. The chaser, which replays the player's own trail `delay` behind on the
wall clock, spent every one of those seconds and ended inside the player. The pause menu does
the same (*"same for using the pause menu"*), and a pause is unbounded. With
`session_policy.chaser_contact` on, a pause menu would park the player inside a damaging ghost —
which is why contact has stayed off (ADR 0047).

## Why only the chaser, and not the recording or the replay ghosts

The user's call, 2026-09-05: *"I only want it to affect chaser, not recordings/replay ghosts"*.
It is also the simpler design. A recording reproduces what was recorded (`_template/README.md`):
a freeze in the file replays as a freeze, and `skip_gaps` already exists for people who want it
trimmed. The chaser is different in kind — it is not a record of the past but a pursuer in the
present, and a pursuer that closes the gap while its quarry cannot move is a rule of the game
being broken, not a faithful picture. So the freeze is cut out of the CHASER'S timeline only.

## Why a clock and not a filter

The obvious fix — stop offering frames while frozen — leaves the chaser's due times on the wall
clock, so the frames already queued still fall due during the freeze and the chaser walks the
remaining `delay` before stopping; and the first frame after the freeze is a `replayGapSeamMs`
gap, which despawns the pack. Both are wrong. Running the chaser on **gameplay time** (wall time
minus every frozen span; `Core.gameplayNowMs`, `gameplayStamp`) fixes both at once: nothing
falls due while the clock stands still, and the frame before and after a freeze are adjacent on
the clock the seam check reads. The render side stays on the wall clock — a fed sample is
converted back at the moment it falls due, since no freeze can sit between a passed due time and
now.

## Why a bridge message, not a field on `local_state`

A field on the sample would go to the recorder and the wire, which this decision says it must
not, and it would be repeated at the adapter's frame rate to carry a value that changes twice a
minute. On-change state is the shape `recording_state` (ADR 0052) and `session_policy` already
use, in the other direction. A repeat of the current value is harmless; an adapter that never
sends it gets today's behaviour exactly.

## The open half: what "frozen" IS in each game

The core cannot know, by the standing rule. Pseudoregalia's signal is unmeasured: the 2026-09-04
probe showed `MovementMode` never changed across the popup, so a "position unchanged for N
samples" heuristic would be a bandage by construction (it fires on a wall-hug, and it fires
late). What is wanted is the game's own fact — a pause state, the input mode a modal switches to
— found with a probe, and the same probe should ask whether a zone transition trips it. The
adapter side of this ADR is that probe, then a `player_frozen` send on change, then the user's
eyes on a chaser across a pause menu.
