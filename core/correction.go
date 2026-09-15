package core

// Error decay: what a ghost does when a new sample says it was drawn in the
// wrong place. Added 2026-09-15 as step A3 of agent_docs/prediction-planning.md.
//
// THE PROBLEM IT REMOVES. The render is stateless: every frame is recomputed
// from the sample buffer, so when a sample arrives that changes where the
// render time falls -- a hole in a loss burst that prediction filled with a
// guess, a peer who reversed while the buffer was dry, a Catmull-Rom bracket
// that just gained its fourth sample -- the ghost teleports to the corrected
// position in one frame. That one-frame jump is the "left/right snap" that
// kept prediction off (ADR 0040, twice by measurement), and delay alone never
// removes it: any render past the newest sample is a guess.
//
// WHAT IT DOES INSTEAD. The buffer remembers the difference between where the
// ghost WAS drawn and where the corrected buffer now puts it, keeps drawing at
// the old place, and lets that difference decay with time constant
// Core.Correction. The ghost slides to the truth instead of jumping there.
// Nothing here is game-aware: the offset is a vector in the adapter's own
// opaque position units, compared only against the peer's own measured speed.
//
// SNAP, NOT DECAY, WHENEVER SLIDING WOULD SHOW A PLACE THE GAME NEVER HAD:
//   - an area_id change or a position-length change between the two renders
//     (the same two discontinuities lerp and extrapolate refuse to cross);
//   - a correction longer than the peer's own top speed could cover in the
//     time a guess can be wrong for (Extrapolate + Correction, with a safety
//     factor). Nobody predicts a warp; a warp from standing still is a jump the
//     game itself made, and the ghost makes it too. Judged against the speed
//     measured BEFORE the new sample landed, or the warp would raise the bound
//     it is tested against;
//   - a peer this core invented (replay, chaser): never predicted, never
//     corrected -- its future is on disk;
//   - a despawn: the buffer goes with it, and a respawn starts clean.
//
// OFF BY DEFAULT. Correction == 0 skips every line here and the render is
// byte-identical to what shipped before this file existed. A game turns it on
// only after the user judges it on screen (prediction-planning.md, "the honest
// limit").

import (
	"math"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// correctionSafetyFactor widens the warp bound: a wrong guess can be wrong by
// twice the distance travelled (predicted forward, peer went back), and speed
// is a decayed maximum that may sit a little under the true one.
const correctionSafetyFactor = 2.5

// correctionEpsilon is where a decayed offset is dropped rather than carried
// forever as a denormal. Position units are the adapter's own; nothing a game
// renders resolves a millionth of a unit.
const correctionEpsilon = 1e-6

// topSpeedDecay is applied to the remembered top speed on every sample that
// does not raise it, so a burst of speed long ago stops widening the warp
// bound after a couple of seconds at the shipped send rate.
const topSpeedDecay = 0.98

// noteSpeed updates the peer's remembered top speed from the newest pair in
// the buffer. Called by add after insertion; a pair too close together to
// carry a rate (minVelocitySpanMs, the same floor extrapolate uses) or one
// that crosses an area or shape change is skipped rather than measured.
func (b *remoteBuffer) noteSpeed() {
	n := len(b.snapshots)
	if n < 2 {
		return
	}
	newer, older := b.snapshots[n-1], b.snapshots[n-2]
	span := newer.Timestamp - older.Timestamp
	if span < minVelocitySpanMs || newer.AreaID != older.AreaID || len(newer.Position) != len(older.Position) {
		return
	}
	var d2 float64
	for i := range newer.Position {
		d := newer.Position[i] - older.Position[i]
		d2 += d * d
	}
	speed := math.Sqrt(d2) / float64(span)
	if speed > b.topSpeed {
		b.topSpeed = speed
	} else {
		b.topSpeed *= topSpeedDecay
	}
}

// decayCorrection advances the offset to nowMs: multiplies it by
// exp(-dt/tau) and drops it once it is below correctionEpsilon. A zero dt
// (the tick that follows the store that set it) leaves it whole, which is
// what makes the drawn position continuous across the correction.
func (b *remoteBuffer) decayCorrection(nowMs, tauMs int64) {
	if b.correction == nil {
		return
	}
	dt := nowMs - b.correctionAt
	b.correctionAt = nowMs
	if dt <= 0 || tauMs <= 0 {
		return
	}
	f := math.Exp(-float64(dt) / float64(tauMs))
	var m2 float64
	for i := range b.correction {
		b.correction[i] *= f
		m2 += b.correction[i] * b.correction[i]
	}
	if m2 < correctionEpsilon*correctionEpsilon {
		b.correction = nil
	}
}

// withCorrection returns st drawn at its offset position. The position is
// COPIED: the state atAhead returns past either edge of the buffer IS the
// edge snapshot, slice and all, and adding into it would rewrite history.
func (b *remoteBuffer) withCorrection(st protocol.State) protocol.State {
	if b.correction == nil || len(b.correction) != len(st.Position) {
		return st
	}
	pos := make([]float64, len(st.Position))
	for i := range pos {
		pos[i] = st.Position[i] + b.correction[i]
	}
	st.Position = pos
	return st
}

// noteCorrection is called by storeRemoteState with the render at the current
// render time as it was DRAWN before the new sample (offset included) and as
// the buffer now computes it. The difference becomes the new offset, unless
// one of the snap rules above applies. speedBefore is the peer's top speed as
// measured before the sample landed; reachMs is how long a guess can have
// been wrong for (Extrapolate + Correction).
func (b *remoteBuffer) noteCorrection(drawn protocol.State, okDrawn bool, now protocol.State, okNow bool, speedBefore float64, reachMs, nowMs int64) {
	if !okDrawn || !okNow || drawn.AreaID != now.AreaID || len(drawn.Position) != len(now.Position) {
		b.correction = nil
		return
	}
	delta := make([]float64, len(now.Position))
	var m2 float64
	for i := range delta {
		delta[i] = drawn.Position[i] - now.Position[i]
		m2 += delta[i] * delta[i]
	}
	if m2 < correctionEpsilon*correctionEpsilon {
		b.correction = nil
		return
	}
	bound := speedBefore * float64(reachMs) * correctionSafetyFactor
	if math.Sqrt(m2) > bound {
		b.correction = nil // a warp: the game jumped, so the ghost jumps
		return
	}
	b.correction = delta
	b.correctionAt = nowMs
}
