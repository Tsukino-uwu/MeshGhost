# 2026-08-30 — The core hands the adapter its orientation bracket, and rotation gets interpolated for the first time

<!-- ADR 0043. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** `bridge.RenderRemote` gains three fields — `orientation_from`, `orientation_to`,
  `interp_t` — naming the two snapshots the core interpolated position between and how far between
  them it rendered. The core still never parses an orientation. **The adapter does the rotation
  interpolation**, because it is the only party that knows what its own orientation means.
- **Status:** **Go side implemented and confirmed with the tools 2026-08-30** — full suite twice,
  `-race`, `internal/e2e`, plus `core/orientbracket_test.go`. **Nothing about how it LOOKS is
  confirmed**; the Pseudoregalia half ships behind `GHOST_ROTATION_SLERP` and the user judges it
  on screen, per the standing rule.
- **Bridge only, never `protocol.State`.** Nothing here crosses the network and no relay sees it:
  both blobs are already on the wire as consecutive samples, so this costs zero bandwidth on the
  link that matters. It is the core telling the adapter, over a local socket, which two it used.

## The problem: orientation was a step function and interpolation delay could not help it

`core/interp.go` has always been explicit that orientation is never interpolated. It is opaque by
contract — a `json.RawMessage` the core is forbidden to parse — so the interpolator takes it from
the **older** of the two bracketing snapshots and holds it until the next real sample passes render
time. Position is smooth; facing snaps at the send rate.

That is **correct for a game with four discrete facings and wrong for one with continuous 3D
rotation**. Pokemon has four directions and TEVI flips a sprite, so the step is the truth there.
Pseudoregalia is the only adapter with continuous rotation, and the user's report says exactly
what the arithmetic predicts: *"a bit choppy/low fps at 20hz and 250ms when turning around fast
but super smooth when turning around slow"*. The visible error is angular velocity divided by Hz —
a 45 deg/s pan steps ~2.3 degrees and is invisible, a 360 deg/s spin steps ~18 degrees and is not.
Identical step **count** either way, which is why the rate never feels like the problem until you
spin fast.

**Corrected mid-investigation:** an earlier reading of this symptom blamed linear *position*
interpolation and was wrong about which field was stepping. The test that settles it is standing
still and spinning — position never changes, so `curve` and `extrapolate` are not in play at all.

## Why the core cannot fix this itself, and why that is not a limitation to route around

An orientation is a compass string for Emerald, a degrees triple for Pseudoregalia, a quaternion
for whatever ships next. There is no midpoint the core can compute without deciding which of those
it is — and deciding is precisely the game knowledge the 2026-08-20 ADR forbids it. Raising the
send rate was the other candidate and is worse: it would only make the steps smaller and pay
bandwidth forever to hide a step that should not be there.

So the split follows the existing one. The core owns TIME — which samples, which fraction, all of
it computed from timestamps it already owns. The adapter owns MEANING. Handing over the bracket
teaches the core nothing: it still cannot read either blob, which is exactly why the interpolation
has to happen on the other side.

## Bracket, not damper — the fork where the easy option is the wrong one

Chasing the newest orientation at a maximum rate is far simpler to write, needs no new fields at
all, and is wrong for a reason that only appears while moving fast. **Position renders an
interpolation delay in the past.** A facing chasing the newest value would put the body where the
peer was and the head where they are now, and the two visibly disagree during exactly the motion
that made anyone look in the first place. Same bracket, same fraction, one clock — the only
version that can reach 1:1.

That argument is also why **`interp_t` can exceed 1**. Under `-extrapolate` the core continues the
arc past the newest sample for the same window it predicts position over, capped the same way and
refused on the same too-stale baseline. A body that predicts while the head lags is the same defect
in a different frame.

## Rotation gets no knobs of its own — it follows the position ones

Asked directly: should `nlerp`/`squad`/damped ship as options the way `curve`/`extrapolate` did?
**No, and zero new config keys.** The lockstep argument generalises: every position knob must apply
to rotation too, or the two fields run on different clocks. So `interp` covers both, `curve:
linear` means shortest-arc, and `extrapolate: 300ms` extrapolates rotation over the same 300ms.

- `nlerp` takes the same path at slightly uneven speed and buys only CPU, which is not the
  constraint here — one rotation per ghost per frame, at most ~18 degrees between samples on a
  fast spin.
- `squad` is rotation's `catmull-rom`. `catmull-rom` shipped as an option in ADR 0040 and TEVI
  chose `linear` anyway, so building the four-sample version for a field that was not interpolated
  **at all** until today is two speculative steps at once. `CurveCatmullRom` deliberately gets the
  straight two-sample arc; pair `squad` with `catmull-rom` if that day comes.

## What the adapter half actually does

Pseudoregalia's orientation is a degrees triple, so the "slerp" reduces to its cheap scalar form:
fold `to - from` into the short half of the range before interpolating, per component. A plain lerp
would send yaw 350 -> 10 **backwards** through 340 degrees instead of forward through 20 — a ghost
spinning the long way round every seam crossing, which is worse than the step it replaces. A
quaternion adapter would apply the same principle by negating one of the pair on a negative dot
product.

**Absence is the pre-existing behaviour, everywhere.** A core predating these fields sends none; a
core with no honest pair to offer — one sample, a render time outside the buffer with prediction
off, or one of the discontinuities `lerp` already refuses to cross — sends none either. The adapter
then uses `orientation` raw, which is byte-for-byte what shipped before. The other three adapters
ignore all three fields and are unaffected.

## The bar, and how it gets judged

**A side-by-side spin**, in the shape already used for renderer comparisons: the local character's
facing is drawn at frame rate, the ghost's at 20 steps a second. A working version makes them
indistinguishable at **every** spin speed. That is the bar — not "better than before".

`GHOST_ROTATION_SLERP` gates the *work*, not the decision (`CLAUDE.md`): `false` compiles the whole
block out and the raw field drives the ghost again, so an A/B on screen means something.

## What this generalises to

Any future 3D adapter inherits the stepped-facing defect the day it ships, and now inherits the fix
with it. The three-family rule behind it — vector quantities lerp directly, cyclic ones need a
shortest-arc correction, discrete ones are never interpolated but only timed — is written up in
`scaling.md` and belongs in `_template/` once this is confirmed on screen.
