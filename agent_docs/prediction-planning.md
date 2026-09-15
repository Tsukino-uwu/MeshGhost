# Plan (started 2026-09-15): prediction without floor-sink or left/right snap

Written 2026-09-14 so the reasoning survives. **Status 2026-09-15: A1 measured and A3 built
(ADR 0069, ships off; screen verdict open); A2 undecided; A4 and Track B untouched.** The numbers
and the session record: `phases/phase10.md`, entry of 2026-09-15.

**Next, in order (2026-09-15):**
1. **The screen verdict on A3 (the user).** `run-netsim.bat` no-arg, two real peers, the second
   held still; both clients at `interp 450ms`, `extrapolate 100ms`, `predict damped`,
   `correction 100ms`. First "identical to 450 linear?", then jump, land, spam left/right, a wall.
   Floor-sink inside a gap is EXPECTED (Track B) and is not a verdict on A3. Off stays shipped
   until this is judged.
2. **A2.0, the sizing numbers (Go side).** Add p95/p99 transit and a dry-gap histogram to the
   client stats line (`core/stats.go`, the meters in `core/interp.go`). With those, `interp` and
   `extrapolate` are arithmetic on the worst-case rig (user's question, 2026-09-15: "can we use
   math instead of testing visually?" — yes for the delay and the window, no for the feel of
   `predict`/`correction`, which get one screen check on the configuration the numbers passed).
3. **A2 proper**, sized from A2.0's numbers; A4 only if A3 shimmers on screen.

**The baseline every step must match on screen: linear interp at 450ms, prediction off. It looks
perfect (user, 2026-09-14).** This plan is worth doing for two reasons. It could lower the delay
for cosmetic ghosts. It also gets ready for a future adapter with more player interaction, where
450ms of lateness costs something real.

## Context: what exists and why it failed

- **The core already predicts, opt-in.** The code is `core/interp.go` (`extrapolate`,
  `velocityBaselineIndex`) and `Core.Extrapolate` / `Core.Predict` (linear / damped / accelerated).
  It is changed live through `SetSmoothing` (`core/settings.go`). Shipped as of 2026-09-14
  (`packaging/release/config.json`): `interp 450ms`, `curve linear`, `extrapolate 0s`,
  `predict damped`. The render is STATELESS: every frame is recomputed from the sample buffer.
- **Failure 1, sinking into the floor.** A falling peer is predicted to keep falling until the
  landing sample arrives, so the ghost goes through the floor. No math on samples alone can know a
  floor is there. The record: `adapters/tevi/UNVERIFIED.md`, `adapters/pseudoregalia/UNVERIFIED.md`,
  `dev-scripts/README.md` ("an adapter-side ground clamp is the only real fix"), and `culling.md`
  (no-prediction ratified 2026-09-01).
- **Failure 2, snapping when moving left/right.** The prediction overshoots in the old direction.
  When the reversal sample arrives, the stateless render teleports back in one frame. The damped
  and accelerated variants moved the error around without removing the jump. The record:
  ADR 0040 ("acceleration is out, by measurement, twice") and `pitfalls/INDEX.md` ("a second
  derivative of network samples is visible no matter how you gate it").
- **What adapters do with a rendered position today.** TEVI sets `transform.position` directly.
  Pseudoregalia teleports the ghost pawn (`SetActorLocationAndRotation`, no sweep, no ground trace)
  and slerps rotation itself from the core's orientation bracket. Emerald and Crystal walk their
  ghosts on the engine's own tile beat. No adapter smooths position again.
- **Constraints.** The core and the relay stay game-blind: no "down", no game units, no floor. The
  relay is untouched by everything here. A wire change is a contract revision with an ADR.

## The honest limit, stated first

Where a remote player is right now is unknowable. Delay is the only approach that is never wrong:
every predictive option trades lateness for being wrong sometimes, and a correction is a position
the game never displayed. **So every step ships OFF.** A game turns one on only after the user
judges it on screen, and only where the lateness it removes is worth more than the corrections cost.

## The options, and where each fits

Industry concepts named here come from general game-networking knowledge, not from anything we
have measured. Per `culling.md`'s provenance rule, check each against a documentation page and date
it before it informs code.

| # | Approach | Fixes lateness | Fixes floor-sink | Fixes L/R snap | Game-blind core | Cost |
|---|---|---|---|---|---|---|
| 1 | Adaptive delay (per-peer jitter buffer) | partly, on good links | n/a (never predicts) | n/a | yes | small |
| 2 | Dead reckoning + error decay | yes | no (bounded only) | yes (smooths it) | yes | small |
| 3 | Better velocity estimate (alpha-beta or Kalman filter) | improves 2 | no | less overshoot | yes | small |
| 4 | Velocity on the wire | improves 2/3/5 | no on its own | reacts a sample sooner | yes (opaque-length array) | contract revision, ~20-30 B/state |
| 5 | Receiver-side game physics (ghost pawn simulates through gaps) | yes | **yes, the game knows the floor** | yes, with 2 | yes (adapter owns it) | per game |
| 6 | Input-driven ghosts (remote presses + state corrections) | yes | yes | yes, most natural | yes (inputs opaque) | largest; needs determinism |
| 7 | "Agree on what was seen" for interactions | not needed | not needed | not needed | yes (event/lease planes) | per game rule |
| 8 | Delay your own player's input | yes | yes | yes | yes | **EXCLUDED: changes the singleplayer game's feel** |

### Is velocity on the wire worth it? (#4)

It is not required, and it does not fix either failure by itself: the sender's velocity still
points down until the frame they land, and nobody knows a reversal is coming. What it does fix:

- **Shimmer.** Velocity derived from sample differences inherits arrival jitter. The game's real
  velocity does not.
- **One sample of reaction lag.** A derived velocity needs two samples after a turn (about 50ms at
  20Hz). A sent one flips on the first.
- **Curves between samples.** With a velocity at every sample, interpolation can curve correctly
  between them (Hermite), which may allow a slightly lower delay with no prediction at all. ADR 0040
  declined Hermite for exactly this reason: it needs velocity on the wire.

At 450ms with no prediction it buys nothing, since interpolation already has real samples on both
sides. **It earns its bytes only together with #5**, where the ghost pawn needs a real velocity to
simulate with. If it is ever added: an optional `velocity` array matching `position`'s length,
opaque to the core like `position` is. The sender adapter reads it from the game (Pseudoregalia's
pawn already has one). An older peer ignores it. It needs an ADR superseding ADR 0040's note, plus
`contract.md` and `_template/PROTOCOL.md`.

## Tracks

### Track A: cosmetic ghosts, lower the delay honestly (core, tools-verified, then screen)

**A1. Measure the headroom first.** Run `run-netsim.bat` with no arguments and two real peers at
450ms. Read the stats line (`transit`, `buffer dry`) to learn how much of the 450 the worst link
really uses, then repeat on a clean localhost link. If dry renders are ~0 on the worst link at
450, that says how much there is to win on good links. The numbers go in the phase file.
**DONE 2026-09-15** (two headless fake-adapter cores per link, six minutes, quic; `phase10.md`):
the worst-case link's transit averages ~200ms and peaks ~470-550ms, so 450 sits at the edge (dry
on ~2% of moving renders, nearly all inside the 1s blackouts); the clean link's transit is ~0 and
never dry, so a good link could render ~350ms earlier. The correlated-loss link (`-loss-burst`, a
different network) is dry on ~6%.

**A2. Adaptive per-peer delay (option 1).** This reopens a parked item in `plans.md`, which logs
per-peer adaptive interp as "not something to work on for now". **Prerequisite A2.0 (above): the
stats line carries only average and max transit, and a delay sized on an average is undersized
by construction.**
- Per peer, delay = (high percentile of transit) + one send interval + margin, clamped to
  `[interp_min, interp]`. **The ABSOLUTE transit, not the jitter range** (corrected 2026-09-15 by
  the A1 reading): samples carry the sender's timestamp on the synced clock and the render time is
  `now − delay`, so a sample must have ARRIVED by the time the render reaches its timestamp. The
  clean link's ~0ms transit is what makes ~100ms serve it. It moves under a slew limit: a render clock that jumps
  is itself a snap, so the delay stretches or compresses time gradually and never skips it.
- New setting `interp_min`, default = `interp`, which means off and byte-identical to today.
  Settable live through `SetSmoothing`.
- `requiredHistoryMsLocked` keeps using the configured `interp` (the upper bound), so history never
  starves.
- The netsim no-arg link must climb back to about 450. That is how the shipped default survives the
  worst-case rule while good links render earlier.
- Tests: a steady link converges below `interp`; a jitter spike raises the delay before the buffer
  runs dry; the slew limit holds (no frame-to-frame render-time jump above the bound); `interp_min ==
  interp` is identical to today; plus a fuzz config field.
- Screen: sweep `interp_min` from bad to good (the user's preference); the user says when it GETS good.

**A3. Error decay as a gap filler (option 2). BUILT 2026-09-15: `core/correction.go`, knob
`correction`, ADR 0069, ships `0s`; eleven tests including the numbers gate; the screen verdict is
open (the config to judge is in the ADR). The design below is what was built, with one addition:
the offset is judged against the peer's top speed as measured BEFORE the new sample, or a warp
would raise its own bound.**
- Per remote, keep a visual `offset` vector. In `storeRemoteState`, under `c.mu`, compute the
  render position at `now` before and after `buf.add`, and add `before − after` to the offset, so
  the ghost stays exactly where it was drawn at the moment a correction lands. Each tick in
  `remoteStatesAt`: rendered = buffer position + offset, then `offset *= exp(−dt / tau)`.
- New setting `correction` (ms, the time constant `tau`); `0` means today's behaviour exactly.
- **Snap instead of decaying** on anything `lerp` already refuses to cross: an `area_id` change, a
  position-length change, a despawn or respawn, and local, replay or chaser peers (never predicted).
- **Detect teleports without game units.** Snap when the correction is larger than the peer's own
  recently measured top speed could cover in `extrapolate + tau`, times a safety factor. A warp
  from standing still snaps; a wrong guess at running speed decays.
- Orientation is untouched here: the core cannot decay an opaque value. An adapter that slerps
  already inherits the bracket.
- Then test config interp 450 (or A2's adaptive delay), `extrapolate` ~100ms, `predict damped`,
  `correction` ~100ms. At 450 the render time only runs past the newest sample during a dry gap, so
  prediction covers holes only. **The expected screen result is "identical to today", and
  smoother through a loss burst.** Floor-sink is still possible inside a gap; Track B fixes that.
- Tests: a reversal produces no frame-to-frame jump beyond the peer's speed bound; `0` is
  byte-identical; a warp snaps; an area change snaps.

**A4. Better velocity estimate (option 3), only if A3 shimmers on screen.** Replace the raw
longest-baseline difference with an alpha-beta filter per axis, per peer. It is state in the buffer,
reset on every discontinuity A3 snaps on. ADR 0040's lesson binds: judge it with everything else
held equal, and drop it if steady motion gets worse. Do not add acceleration.

### Track B: a future interaction-heavy adapter (adapter-side, the user verifies on screen)

**B1. Receiver-side game physics (option 5), which fixes the floor for real.** When the buffer runs
dry, the adapter stops teleporting the ghost pawn and lets the game move it: hand the pawn a
velocity (derived by the core, or sent, per #4) and let the engine's own movement and collision
carry it, so it lands on the floor and stops at walls. When samples resume, pull toward the core's
position with A3's decay rather than a teleport.
- It stays cosmetic: the ghost blocks nothing and is not solid to the player (`session_policy`
  still binds), and nothing is written to game state. Collision is used only so the ghost itself
  cannot enter geometry.
- The lighter version, if full simulation is too much for a game: a **collision clamp**. Sweep from
  the newest real position to the predicted one with the game's own trace, and stop at the hit.
- Bridge need: the adapter must know when a render is predicted rather than interpolated (a
  `predicted` flag, or the `interp_t > 1` it already gets for rotation) and, for full simulation, a
  velocity. That is an additive bridge field and an ADR.
- Pitfall already on file: a position corrector that STOPS the pawn kills its movement mechanics;
  carry velocity across the correction (`pitfalls/INDEX.md`, Pseudoregalia 2026-09-09).
- Back-port to `_template/README.md` as an optional capability.

**B2. Velocity on the wire (option 4), as B1's helper.** Only once B1 exists and the derived velocity
is measured to fall short on screen (a late reaction or shimmer). See the section above.

**B3. Input-driven ghosts (option 6).** The ghost pawn is fed the remote player's presses, with
state samples correcting drift. That gives the most natural motion: the ghost really jumps, lands
and turns with the game's own code. The building blocks exist for replays (`input_sample` and
`remote_input`, ADR 0056/0057); live peers would need the input track on the wire, which is a
contract revision. It is blocked per game on determinism and is the largest job. Never feed an
input to anything but a ghost pawn the adapter spawned.

**B4. Interactions judge what was seen (option 7).** If an adapter ever has hits or contact that
matter, don't make the ghost more current: agree on what the viewer saw. The viewer reports "I hit
what was on my screen at render time T", and the rule for accepting it lives in the game's
adapter on the event/lease planes. `chaser_contact` (ADR 0047) is the only contact that exists
today, and it stays local. Read `beyond-cosmetic.md` first; the per-game rule needs its own ADR and
the user's intent confirmed first.

### Dropped from the earlier draft

- **A per-axis prediction mask declared by the adapter.** It stopped floor-sink by never predicting
  the vertical axis, but it froze that axis in every gap and did nothing about walls. B1 fixes the
  floor properly, with the game's own collision.

## Verification

- **Go side (mine).** `dev-scripts/run-gotests.bat` green. `run-gotests-race.bat` for A2/A3/A4 (all
  on `c.mu` paths), at `-count=10`. Every behaviour change gets a regression test that fails
  without it. Rebuild the root `meshghost*.exe` with `-o` before any launcher test. Read
  `gh run list -L 5` after the `.go` commit.
- **Numbers before screen.** A Go test drives a synthesized walk (tests synthesize clips; nothing
  recorded is checked in) through a simulated netsim-shaped link and asserts: the largest
  frame-to-frame jump (A3, `TestCorrectionOnANetsimShapedLink`), the render-time slew (A2), and the
  average lateness against the 450 baseline. Numbers decide whether a step is ready to show, never
  whether it is good.
- **Screen (the user).** `run-netsim.bat` with no arguments, two real peers, the second client held
  still while the user watches their own ghost. For each step: first "does it look identical to 450
  linear?", then jump, land, spam left/right, and run into a wall. The verdict is judged on the
  worst-case link only.
- **Records.** A dated entry in the active phase file for each step. A new ADR for anything that
  touches the contract or the bridge, indexed in `architecture.md`. The stale "shipped 250ms"
  comment on `Core.Extrapolate` (`core/core.go`) was fixed 2026-09-15.
