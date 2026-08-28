# 2026-08-28 — A client stops restating an unchanged state, and brackets its resume so nothing creeps

<!-- ADR 0039. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** A core no longer sends a state identical to the last one it sent. `IdleKeepalive`
  (`-keepalive`, default **250ms**) is the floor at which an unchanged state goes out anyway, and
  setting it to `0` disables suppression entirely, restoring the pre-2026-08-28 behaviour of
  sending every frame that survives rate limiting. On resume — the first state that differs after
  anything was skipped — the core sends a **bracket**: the last state again, stamped one
  millisecond before the changed one.
- **Status:** **Implemented 2026-08-28, Go side complete and confirmed with the tools.** Full
  suite, `-race`, `internal/e2e` included. `core/suppress_test.go` covers suppression, the
  keepalive, the disable switch, opaque fields counting as changes, and the resume.
  **Unmeasured in a real session** — the saving is arithmetic, not an observation, and TEVI in
  particular is expected to save almost nothing (below).

## Why

Requested twice by the user (2026-08-21, 2026-08-28): *"clients should not send new values if they
have not changed since the previous ones"*, and the goal behind it — *"make the server/client parts
a bit more efficient, so they eat less cpu/bandwidth. while still functioning the same
gameplay/visually"*. Most of a singleplayer session is spent standing still, and a standing player
uploads a byte-identical packet at the room's full rate — 20Hz shipped, 100Hz on the dev rig — which
the relay then fans out to every peer in the room, for no movement on anyone's screen.

**It lives in the core, and that is the whole reason it is cheap.** "Is this value the same as the
last one" needs no knowledge of what the value means, so it is game-agnostic by construction
(`internal/gameblind` still passes) and one implementation serves all four adapters instead of four.

## The part that decides the design: a receiver interpolates across a silence

`core/interp.go`'s `lerp` blends between the two samples bracketing the render time. Suppression
widens that gap, so a peer that stood still and then walked would render as a ghost **creeping**
across the whole silence at a fraction of walking speed — `adapters/CLAUDE.md`'s "never move a
ghost slower than the game moves", broken by a bandwidth optimisation, which is not a trade this
project makes.

The bracket removes it exactly rather than approximately: re-stating the unchanged state 1ms before
the changed one means the receiver holds the standing position until the instant the peer genuinely
moved, then moves at the peer's own true rate. `TestAResumeAfterSilenceDoesNotMakeAGhostCreep` is
the regression test, and it checks the rendered position out of a real `remoteBuffer` rather than
the packet count — the packets were never the thing at risk.

## Why a keepalive rather than silence, and why 250ms

Three things need the floor, and only the first is about bandwidth:

- **The relay must keep telling quiet from gone**, which the udp path already gets wrong for up to
  60s (`status.md`).
- **A late joiner has never seen a state from this player** and would otherwise wait for them to
  move.
- **On udp a suppressed packet's loss lasts until the next send**, so without a floor a single
  dropped resume could leave a ghost stale indefinitely.

250ms is `DefaultInterpolationDelay`'s figure on purpose: a ghost is already rendered that far
behind, so a staleness bound of the same size cannot become the dominant error. At a 20Hz room an
idle player goes from 20 packets a second to 4; on the 100Hz dev rig, from 100 to 4.

## What this does NOT do, stated so nobody re-measures it hoping

- **TEVI saves almost nothing.** It sends animation phase (`anim_time`) every frame, and an idle
  breathing loop advances it continuously — so TEVI's "idle" states are never identical and nothing
  is suppressed. Its win needs either the per-field version below, or a decision about when phase
  has to travel, which is a 1:1 question and not a bandwidth one.
- **Per-field deltas are still unbuilt** (`ideas.md`, "third rung"). Making wire fields optional
  with "unchanged" as the default meaning is a protocol revision with its own resend rules for late
  joiners, reconnects and lossy udp. This ADR is deliberately the half that needs none of that.
- **Nothing was measured in a real session.** The counters exist for that: `StatesSuppressed` and
  `BracketsSent`, both in the `-stats` line, where the second is the cost of the first.
