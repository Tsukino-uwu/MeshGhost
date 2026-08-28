package core

// The Catmull-Rom curve mode: opt-in, off by default, and required to be
// EXACTLY the straight line whenever the samples are straight -- which is what
// makes it safe to try on a game without first proving anything about it.

import (
	"math"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func at2D(ts int64, x, y float64) protocol.State {
	return protocol.State{AreaID: "a", Position: []float64{x, y}, Anim: "walk", Timestamp: ts}
}

func TestTheCurveIsOffByDefault(t *testing.T) {
	var b remoteBuffer
	// An arc: constant x step, accelerating y.
	b.add(at2D(1000, 0, 0))
	b.add(at2D(1100, 10, 0))
	b.add(at2D(1200, 20, 10))
	b.add(at2D(1300, 30, 30))

	straight, _ := b.at(1150)
	// Straight-line answer between (10,0) and (20,10) at the halfway point.
	if straight.Position[0] != 15 || straight.Position[1] != 5 {
		t.Fatalf("default render gave %v, want the straight line (15, 5)", straight.Position)
	}
}

func TestTheCurveDiffersFromTheStraightLineOnAnArc(t *testing.T) {
	var b remoteBuffer
	b.add(at2D(1000, 0, 0))
	b.add(at2D(1100, 10, 0))
	b.add(at2D(1200, 20, 10))
	b.add(at2D(1300, 30, 30))

	curved, _ := b.atAhead(1150, 0, CurveCatmullRom, PredictAccelerated, nil)
	straight, _ := b.atAhead(1150, 0, CurveLinear, PredictAccelerated, nil)
	if curved.Position[1] == straight.Position[1] {
		t.Fatalf("the curve returned the straight-line y (%v) on an arc -- it is not fitting anything",
			curved.Position[1])
	}
	// It still has to stay in the neighbourhood: a spline that wanders far
	// from its own control points is a bug, not a smoother path.
	if math.Abs(curved.Position[1]-straight.Position[1]) > 5 {
		t.Fatalf("curved y = %v against a straight-line %v -- too far from the samples to be a fit",
			curved.Position[1], straight.Position[1])
	}
}

// The one property that makes this safe to enable blind: on collinear,
// evenly-spaced samples the spline IS the straight line. A game that moves in
// a straight line at a constant rate renders identically in both modes.
func TestTheCurveIsExactlyLinearOnAStraightPath(t *testing.T) {
	var b remoteBuffer
	for i := 0; i < 4; i++ {
		b.add(at2D(1000+int64(i)*100, float64(i)*10, 0))
	}

	for _, rt := range []int64{1105, 1130, 1150, 1175, 1199} {
		curved, _ := b.atAhead(rt, 0, CurveCatmullRom, PredictAccelerated, nil)
		straight, _ := b.atAhead(rt, 0, CurveLinear, PredictAccelerated, nil)
		if math.Abs(curved.Position[0]-straight.Position[0]) > 1e-9 {
			t.Fatalf("at %d the curve gave x=%v and the line gave x=%v -- a straight path must render identically",
				rt, curved.Position[0], straight.Position[0])
		}
	}
}

// Fewer than four samples, or a discontinuity among them, and it falls back to
// the straight line rather than fitting a curve across the seam.
func TestTheCurveFallsBackWhenItCannotSeeFourGoodSamples(t *testing.T) {
	var b remoteBuffer
	b.add(at2D(1000, 0, 0))
	b.add(at2D(1100, 10, 0))

	// Between the two, not past them -- past the newest sample is the holding
	// case, which is a different branch with its own tests.
	got, _ := b.atAhead(1050, 0, CurveCatmullRom, PredictAccelerated, nil)
	if got.Position[0] != 5 {
		t.Fatalf("with two samples the curve gave x=%v, want the straight line (5)", got.Position[0])
	}

	var c remoteBuffer
	c.add(at2D(1000, 0, 0))
	c.add(at2D(1100, 10, 0))
	crossed := at2D(1200, 20, 10)
	crossed.AreaID = "b"
	c.add(crossed)
	c.add(at2D(1300, 30, 30))

	// The straight line's own area guard then takes over and holds the older
	// sample rather than blending two unrelated coordinate spaces (see lerp),
	// so the answer here is the pre-curve behaviour exactly.
	got, _ = c.atAhead(1150, 0, CurveCatmullRom, PredictAccelerated, nil)
	if got.Position[0] != 10 || got.Position[1] != 0 {
		t.Fatalf("across an area change the curve gave %v, want the older sample held (10, 0)", got.Position)
	}
}
