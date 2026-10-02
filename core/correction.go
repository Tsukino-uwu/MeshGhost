package core

// Error decay: when a new sample moves where a remote ghost belongs, the drawn spot is kept as an offset decaying with
// time constant Core.Correction, so the ghost slides instead of jumping. It snaps wherever a slide would show a place
// the game never had: an area or position-length change, a correction farther than the peer's measured top speed
// could cover (a warp), a ghost this core invented, a despawn. Correction == 0 skips all of it.

import (
	"math"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// correctionSafetyFactor widens the warp bound: a wrong guess can be wrong by twice the distance travelled (predicted
// forward, peer went back), and speed is a decayed maximum that may sit a little under the true one.
const correctionSafetyFactor = 2.5

// correctionEpsilon is where a decayed offset is dropped rather than carried as a denormal; no game resolves a
// millionth of a unit.
const correctionEpsilon = 1e-6

// topSpeedDecay shrinks the remembered top speed on every sample that does not raise it, so an old burst of speed
// stops widening the warp bound.
const topSpeedDecay = 0.98

// noteSpeed updates the peer's remembered top speed from the newest pair; a pair too close to carry a rate
// (minVelocitySpanMs), or across an area or shape change, is skipped.
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

// decayCorrection advances the offset to nowMs by exp(-dt/tau). A zero dt leaves it whole, which keeps the drawn
// position continuous across the correction.
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

// withCorrection returns st drawn at its offset. The position is copied: past either edge of the buffer, atAhead
// returns the edge snapshot itself, slice and all, and adding into it would rewrite the buffer.
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

// noteCorrection makes the difference between the render as drawn before the new sample and as the buffer now
// computes it the new offset, unless a snap applies. speedBefore is measured before the sample landed, or a warp would
// raise its own bound; reachMs is how long a guess can have been wrong for (Extrapolate + Correction).
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
