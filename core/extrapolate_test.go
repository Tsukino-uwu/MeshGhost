package core

// Prediction: drawing a ghost past its newest sample by continuing the last
// measured velocity. Opt-in (Core.Extrapolate / -extrapolate), off by default.
//
// These tests fix the SHAPE of the prediction -- that it is off unless asked
// for, that it is capped, and that it refuses to measure a velocity it cannot
// trust. Whether it LOOKS better than holding the last sample is a per-game
// question that only a screen can answer, and this file cannot.

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func sample(ts int64, x float64) protocol.State {
	return protocol.State{AreaID: "a", Position: []float64{x, 0}, Anim: "walk", Timestamp: ts}
}

// The default must be exactly what it always was: hold the newest sample.
func TestWithoutExtrapolationTheNewestSampleIsHeld(t *testing.T) {
	var b remoteBuffer
	b.add(sample(1000, 0))
	b.add(sample(1100, 10)) // 10 units in 100ms

	got, ok := b.at(1200)
	if !ok {
		t.Fatal("no state at 1200")
	}
	if got.Position[0] != 10 {
		t.Fatalf("held position = %v, want 10 -- something extrapolated without being asked", got.Position[0])
	}
}

func TestExtrapolationContinuesTheLastVelocity(t *testing.T) {
	var b remoteBuffer
	b.add(sample(1000, 0))
	b.add(sample(1100, 10)) // 0.1 units/ms

	got, ok := b.atAhead(1150, 100, CurveLinear, PredictAccelerated, nil)
	if !ok {
		t.Fatal("no state at 1150")
	}
	// 50ms past the newest sample at 0.1 units/ms.
	if got.Position[0] != 15 {
		t.Fatalf("predicted position = %v, want 15", got.Position[0])
	}
	if got.Timestamp != 1150 {
		t.Fatalf("predicted timestamp = %d, want the render time 1150", got.Timestamp)
	}
}

// A peer who goes quiet must freeze where they were last seen rather than
// walking off the map forever.
func TestExtrapolationIsCapped(t *testing.T) {
	var b remoteBuffer
	b.add(sample(1000, 0))
	b.add(sample(1100, 10))

	got, _ := b.atAhead(9999, 100, CurveLinear, PredictAccelerated, nil)
	// Capped at 100ms past the newest sample: 10 + 0.1*100.
	if got.Position[0] != 20 {
		t.Fatalf("predicted position = %v after a long silence, want the 100ms cap (20)", got.Position[0])
	}
}

// The suppression bracket puts two samples 1ms apart on the wire by design.
// Measuring a velocity over that pair would turn a few units of movement into
// hundreds -- a ghost fired across the screen on every resume.
func TestExtrapolationRefusesToMeasureOverTheResumeBracket(t *testing.T) {
	var b remoteBuffer
	b.add(sample(1000, 100)) // standing
	b.add(sample(1500, 100)) // the bracket: same position, much later
	b.add(sample(1501, 108)) // the first moving sample, 1ms after it

	got, _ := b.atAhead(1600, 100, CurveLinear, PredictAccelerated, nil)
	// The only pair far enough apart to measure is the two standing samples,
	// whose velocity is zero -- so the honest answer is to hold, not to fly.
	if got.Position[0] != 108 {
		t.Fatalf("predicted position = %v, want the newest sample (108) held -- a 1ms pair was used as a velocity", got.Position[0])
	}
}

// The same two guards lerp applies, for the same reason: a blend or a
// prediction across an area change is a blend across two unrelated coordinate
// spaces (see the 2026-08-13 cross-area ADR).
func TestExtrapolationRefusesToCrossAnAreaChange(t *testing.T) {
	var b remoteBuffer
	older := sample(1000, 0)
	newer := sample(1100, 10)
	newer.AreaID = "b"
	b.add(older)
	b.add(newer)

	got, _ := b.atAhead(1200, 100, CurveLinear, PredictAccelerated, nil)
	if got.Position[0] != 10 {
		t.Fatalf("predicted position = %v across an area change, want the newest sample (10) held", got.Position[0])
	}
}

func TestExtrapolationHoldsAStandingPeer(t *testing.T) {
	var b remoteBuffer
	b.add(sample(1000, 42))
	b.add(sample(1100, 42))

	got, _ := b.atAhead(1300, 200, CurveLinear, PredictAccelerated, nil)
	if got.Position[0] != 42 {
		t.Fatalf("predicted position = %v for a peer that never moved, want 42", got.Position[0])
	}
}

// One sample is not a velocity.
func TestExtrapolationNeedsTwoSamples(t *testing.T) {
	var b remoteBuffer
	b.add(sample(1000, 7))

	got, ok := b.atAhead(2000, 500, CurveLinear, PredictAccelerated, nil)
	if !ok {
		t.Fatal("no state from a single sample")
	}
	if got.Position[0] != 7 {
		t.Fatalf("predicted position = %v from one sample, want 7 held", got.Position[0])
	}
}

// A JUMP IS AN ACCELERATING BODY, and predicting one along a straight line is
// what made a ghost lag on the way up and sink through the floor on the way
// down (user, 2026-08-28, over a simulated bad link). With three samples the
// prediction includes acceleration, so a parabola is predicted as a parabola.
func TestPredictionFollowsAnAcceleratingBody(t *testing.T) {
	var b remoteBuffer
	// y = 100 - 5t^2 in units of 10ms steps: a body falling under gravity.
	for i := 0; i < 4; i++ {
		tt := float64(i)
		b.add(protocol.State{
			AreaID: "a", Anim: "fall",
			Position:  []float64{0, 100 - 5*tt*tt},
			Timestamp: 1000 + int64(i)*10,
		})
	}
	// One more step of the same fall would put it at t=4: 100 - 5*16 = 20.
	got, ok := b.atAhead(1040, 100, CurveLinear, PredictAccelerated, nil)
	if !ok {
		t.Fatal("no state at 1040")
	}
	want := 20.0
	// Straight-line prediction from the last pair would give 100-5*9 - (the
	// last step) = far above the true value; anything near it means the
	// acceleration term is missing.
	if diff := got.Position[1] - want; diff > 2 || diff < -2 {
		t.Fatalf("predicted y=%v for a falling body, want about %v -- the prediction is not following the curve",
			got.Position[1], want)
	}
}

// PredictDamped: predict what is predictable, per axis. A ghost running
// steadily sideways while falling should have its horizontal motion predicted
// in full and its vertical motion barely at all -- which is the shape of the
// complaint that produced this mode (user, 2026-08-28: left/right fine, up/down
// a "constant snap/drag").
func TestDampedPredictionTrustsASteadyAxisAndNotAChangingOne(t *testing.T) {
	var b remoteBuffer
	// x advances 10 per step (steady); y falls with acceleration.
	for i := 0; i < 4; i++ {
		tt := float64(i)
		b.add(protocol.State{
			AreaID: "a", Anim: "fall",
			Position:  []float64{tt * 10, 100 - 5*tt*tt},
			Timestamp: 1000 + int64(i)*10,
		})
	}
	last, _ := b.at(1030)
	got, _ := b.atAhead(1040, 100, CurveLinear, PredictDamped, nil)

	// Horizontal: a steady 1 unit/ms, so a 10ms prediction should advance it
	// nearly the full 10 units.
	if dx := got.Position[0] - last.Position[0]; dx < 8 {
		t.Fatalf("steady axis advanced by %v over 10ms, want close to 10 -- damping is suppressing a predictable axis", dx)
	}
	// Vertical: the velocity is changing every step, so most of the prediction
	// is withheld. THIS CONTRACT WAS FLIPPED AND FLIPPED BACK on 2026-08-28:
	// a consistency-gated acceleration followed this parabola beautifully in
	// the test and produced chop and a stopping snap on screen, because the
	// gate's contribution fluctuates under jitter. Velocity-only damping is
	// the measured winner; the jump's residual lag is the accepted price.
	if dy := last.Position[1] - got.Position[1]; dy > 15 {
		t.Fatalf("changing axis was predicted %v further down, want it heavily damped", dy)
	}
}

// Curvature must never be extended by damped prediction -- consistent or not;
// see the contract note above. This pins the noisy case separately so a future
// re-attempt at acceleration trips both tests, not one.
func TestDampedPredictionRefusesInconsistentCurvature(t *testing.T) {
	var b remoteBuffer
	ys := []float64{100, 97, 99, 90} // wobbling downward: accel flips sign
	for i, y := range ys {
		b.add(protocol.State{
			AreaID: "a", Anim: "fall",
			Position:  []float64{0, y},
			Timestamp: 1000 + int64(i)*10,
		})
	}
	last, _ := b.at(1030)
	got, _ := b.atAhead(1040, 100, CurveLinear, PredictDamped, nil)
	// The velocity here is genuinely downward, so some prediction is fine; what
	// must NOT happen is the noisy curvature being extended into a plunge.
	if dy := last.Position[1] - got.Position[1]; dy > 12 {
		t.Fatalf("inconsistent curvature was extended %v further down -- the accelerated mode's failure is back", dy)
	}
}

// The apex of a jump: the velocity reverses, so there is almost nothing worth
// extending -- but not NOTHING. Refusing outright was the first version and it
// was wrong on screen: spam-tapping left and right reverses an axis constantly,
// and a ghost that stops predicting there falls back to a full interpolation
// delay behind, which the user read as "slow/delayed" while long runs looked
// fine (2026-08-28). minPredictConfidence is the floor that answers it, and
// this test pins the trade: heavily damped, never zero.
func TestDampedPredictionHeavilyDampsAReversingAxis(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{AreaID: "a", Position: []float64{0, 0}, Timestamp: 1000})
	b.add(protocol.State{AreaID: "a", Position: []float64{0, 10}, Timestamp: 1010})
	b.add(protocol.State{AreaID: "a", Position: []float64{0, 0}, Timestamp: 1020})

	got, _ := b.atAhead(1030, 100, CurveLinear, PredictDamped, nil)
	// Up then down by the same amount: v1 = +1, v2 = -1, so the raw confidence
	// is 0 and only the floor survives. Undamped this would predict -10.
	want := -10 * minPredictConfidence
	if diff := got.Position[1] - want; diff > 0.01 || diff < -0.01 {
		t.Fatalf("a reversing axis was predicted to y=%v, want %v -- the floor is the whole prediction here",
			got.Position[1], want)
	}
	if got.Position[1] <= -10 {
		t.Fatalf("a reversing axis got the FULL prediction (y=%v) -- damping is not applying", got.Position[1])
	}
}
