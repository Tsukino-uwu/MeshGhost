package core

import (
	"encoding/json"
	"math"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// Prediction defects reachable only with -extrapolate, which ships off: they all turn on the moment prediction is
// tuned.

// fillBuffer builds a buffer from (timestamp, x) pairs in one area: motion on a single axis, so the arithmetic in the
// comments is the arithmetic in the assertion.
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

// TestPredictionRefusesToMeasureOverTheResumeBracket: the damped and accelerated modes measure two more velocities off
// the middle sample, and change suppression makes that sample the 1ms resume bracket, so both legs need
// minVelocitySpanMs too, or a peer who steps off from standing still is fired seconds ahead in one frame.
func TestPredictionRefusesToMeasureOverTheResumeBracket(t *testing.T) {
	// Standing still at x=100, then the resume bracket at 1599 and the first moved sample 1ms later.
	b := fillBuffer([2]float64{1250, 100}, [2]float64{1500, 100}, [2]float64{1599, 100}, [2]float64{1600, 103})

	// 3 units in the 100ms baseline the outer guard picked, carried 100ms forward.
	const want = 106.0

	for _, mode := range []PredictMode{PredictDamped, PredictAccelerated} {
		st, ok := b.atAhead(1700, 100, CurveLinear, mode, nil)
		if !ok {
			t.Fatalf("%s: no state", mode)
		}
		if math.Abs(st.Position[0]-want) > 0.001 {
			t.Errorf("%s predicted x=%g, want %g -- a 1ms leg was read as a velocity", mode, st.Position[0], want)
		}
	}
}

// TestAnUnsetPredictModeIsLinear: Core.Predict's zero value is PredictLinear, so the empty string must not fall through
// to the accelerated branch, the mode that failed on screen. cmd/meshghost defaults the flag; a Core literal does not.
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
	if math.Abs(unset.Position[0]-50) > 0.001 {
		t.Errorf("an unset Predict gave x=%g (accelerated is %g); the zero value must be linear", unset.Position[0], accel.Position[0])
	}
	// An undefined mode lands there too: a typo renders the shipped behaviour, not the mode with the largest error.
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

// TestTheOrientationBracketMeasuresOverThePositionBaseline: past the newest sample the bracket uses the pair the
// position's velocity does; the adjacent pair makes T = (span+dt)/span unbounded as span falls towards 1ms.
func TestTheOrientationBracketMeasuresOverThePositionBaseline(t *testing.T) {
	// The peer turned as they started walking: the 1ms bracket re-statement lies across the turn.
	turned := orientedBuffer(t,
		[3]any{1000, 100.0, `"a"`},
		[3]any{1500, 105.0, `"a"`},
		[3]any{1501, 108.0, `"b"`},
	)
	st, br, ok := turned.atBracket(1600, 100, CurveLinear, PredictLinear, nil)
	if !ok {
		t.Fatal("no state")
	}
	// Position holds: no pair in the window is both recent enough and long enough to measure a rate over.
	if math.Abs(st.Position[0]-108) > 0.001 {
		t.Fatalf("fixture drifted: position predicted x=%g, want the held 108", st.Position[0])
	}
	// A bracket here would turn the head a hundred times in one frame while the body holds.
	if br.Have {
		t.Errorf("orientation bracket T=%g over a 1ms pair while position refused to predict at all", br.T)
	}

	// Positive control, proving it is the same pair and not merely a second bound: the baseline (the oldest inside
	// maxVelocitySpanMs) is snapshots[0], where the adjacent pair would start at snapshots[1].
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
	// (1150 + 50 - 1000) / 150; the adjacent pair would give 2.
	if want := 200.0 / 150.0; math.Abs(br.T-want) > 0.001 {
		t.Errorf("bracket T=%g, want %g -- the fraction must come from the same span the velocity did", br.T, want)
	}
}
