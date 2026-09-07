package core

import (
	"encoding/json"
	"math"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The three prediction defects found by the 2026-09-07 review pass and fixed
// 2026-09-08. All three are reachable only with -extrapolate, which ships off
// (0s), so none of them was ever on a player's screen -- they are what turns on
// together the moment somebody tunes prediction, which is why they get tests
// rather than a note.

// fill builds a buffer from (timestamp, x) pairs in one area, the shape every
// case below wants: motion on a single axis so the arithmetic in the comments
// is the arithmetic in the assertion.
func fillBuffer(pairs ...[2]float64) *remoteBuffer {
	b := &remoteBuffer{}
	for _, p := range pairs {
		b.add(protocol.State{
			PlayerID:  "peer",
			Timestamp: int64(p[0]),
			AreaID:    "room",
			Position:  []float64{p[1]},
		})
	}
	return b
}

// TestPredictionRefusesToMeasureOverTheResumeBracket is E14. The outer
// baseline is guarded by minVelocitySpanMs; the damped and accelerated modes
// measure two more velocities off the middle sample, and those were checked
// only for being positive. Change suppression spaces an idle peer's samples
// out, so the sample nearest the midpoint is the 1ms bracket re-statement that
// forwardLocalState puts before the first state of real movement -- a peer who
// has been standing still takes one step and is fired seconds of walking, or
// off the level entirely, in a single frame.
func TestPredictionRefusesToMeasureOverTheResumeBracket(t *testing.T) {
	// Standing still at x=100, then the resume bracket at 1599 and the first
	// moved sample 1ms later.
	b := fillBuffer([2]float64{1250, 100}, [2]float64{1500, 100}, [2]float64{1599, 100}, [2]float64{1600, 103})

	// The truth: 3 units in the 100ms baseline the outer guard picked, carried
	// 100ms forward, is 106.
	const want = 106.0

	for _, mode := range []PredictMode{PredictDamped, PredictAccelerated} {
		st, ok := b.atAhead(1700, 100, CurveLinear, mode, nil)
		if !ok {
			t.Fatalf("%s: no state", mode)
		}
		// Before the fix: 223 damped (the confidence floor times a 3 units/ms
		// leg) and 706 accelerated (that leg plus its curvature).
		if math.Abs(st.Position[0]-want) > 0.001 {
			t.Errorf("%s predicted x=%g, want %g -- a 1ms leg was read as a velocity", mode, st.Position[0], want)
		}
	}
}

// TestAnUnsetPredictModeIsLinear is E16. Core.Predict documents its zero value
// as PredictLinear and Curve honours the same promise for its own; this file
// compared against PredictLinear by equality, so the empty string fell through
// to the accelerated branch -- the mode the comments in interp.go record as
// having failed on screen twice. cmd/meshghost defaults the flag, so only an
// in-process Core literal, an embedder or a fuzz target could reach it.
func TestAnUnsetPredictModeIsLinear(t *testing.T) {
	// Accelerating: 10 units in the first 100ms, 30 in the second.
	b := fillBuffer([2]float64{1000, 0}, [2]float64{1100, 10}, [2]float64{1200, 40})

	linear, ok := b.atAhead(1250, 100, CurveLinear, PredictLinear, nil)
	if !ok {
		t.Fatal("no state")
	}
	if math.Abs(linear.Position[0]-50) > 0.001 {
		t.Fatalf("fixture drifted: linear predicted x=%g, want 50", linear.Position[0])
	}
	accel, ok := b.atAhead(1250, 100, CurveLinear, PredictAccelerated, nil)
	if !ok {
		t.Fatal("no state")
	}
	if math.Abs(accel.Position[0]-62.5) > 0.001 {
		t.Fatalf("fixture drifted: accelerated predicted x=%g, want 62.5", accel.Position[0])
	}

	unset, ok := b.atAhead(1250, 100, CurveLinear, PredictMode(""), nil)
	if !ok {
		t.Fatal("no state")
	}
	// Before the fix this was 62.5 -- the accelerated answer for a Core that
	// asked for nothing.
	if math.Abs(unset.Position[0]-50) > 0.001 {
		t.Errorf("an unset Predict gave x=%g (accelerated is %g); the zero value must be linear", unset.Position[0], accel.Position[0])
	}
	// A mode nobody defined lands in the same place, which is the safe
	// direction: a typo renders the shipped behaviour rather than the mode
	// with the largest error.
	typo, _ := b.atAhead(1250, 100, CurveLinear, PredictMode("linaer"), nil)
	if math.Abs(typo.Position[0]-50) > 0.001 {
		t.Errorf("an unrecognised Predict gave x=%g, want the linear %g", typo.Position[0], 50.0)
	}
}

func orientedBuffer(t *testing.T, samples ...[3]any) *remoteBuffer {
	t.Helper()
	b := &remoteBuffer{}
	for _, s := range samples {
		b.add(protocol.State{
			PlayerID:    "peer",
			Timestamp:   int64(s[0].(int)),
			AreaID:      "room",
			Position:    []float64{s[1].(float64)},
			Orientation: json.RawMessage(s[2].(string)),
		})
	}
	return b
}

// TestTheOrientationBracketMeasuresOverThePositionBaseline is E15. The
// bracket's own doc says "Same bracket, same fraction, one clock", and past
// the newest sample it took the ADJACENT pair with only the upper span guard
// applied -- so T = (span+dt)/span was unbounded as span fell towards 1ms.
func TestTheOrientationBracketMeasuresOverThePositionBaseline(t *testing.T) {
	// The peer turned as they started walking: half a second of standing
	// still, then the 1ms bracket re-statement across the turn.
	turned := orientedBuffer(t,
		[3]any{1000, 100.0, `"a"`},
		[3]any{1500, 105.0, `"a"`},
		[3]any{1501, 108.0, `"b"`},
	)
	st, br, ok := turned.atBracket(1600, 100, CurveLinear, PredictLinear, nil)
	if !ok {
		t.Fatal("no state")
	}
	// Position holds: no pair in the window is both recent enough and long
	// enough to measure a rate over.
	if math.Abs(st.Position[0]-108) > 0.001 {
		t.Fatalf("fixture drifted: position predicted x=%g, want the held 108", st.Position[0])
	}
	// Before the fix: Have true with T = 100 -- the body standing still while
	// the head slerped through a hundred turns in one frame.
	if br.Have {
		t.Errorf("orientation bracket T=%g over a 1ms pair while position refused to predict at all", br.T)
	}

	// Positive control, and the half that proves it is the same PAIR and not
	// merely a second bound: three samples 150ms apart end to end, where the
	// baseline (the oldest still inside maxVelocitySpanMs) is snapshots[0] and
	// the adjacent pair the old code used was snapshots[1].
	walking := orientedBuffer(t,
		[3]any{1000, 0.0, `"a"`},
		[3]any{1100, 10.0, `"b"`},
		[3]any{1150, 15.0, `"c"`},
	)
	_, br, ok = walking.atBracket(1200, 100, CurveLinear, PredictLinear, nil)
	if !ok {
		t.Fatal("no state")
	}
	if !br.Have {
		t.Fatal("no bracket over a pair position happily measures a velocity over")
	}
	if string(br.From) != `"a"` || string(br.To) != `"c"` {
		t.Errorf("bracket runs %s->%s, want the baseline pair \"a\"->\"c\"", br.From, br.To)
	}
	// (1150 + 50 - 1000) / 150. The old adjacent-pair answer was 2.
	if want := 200.0 / 150.0; math.Abs(br.T-want) > 0.001 {
		t.Errorf("bracket T=%g, want %g -- the fraction must come from the same span the velocity did", br.T, want)
	}
}
