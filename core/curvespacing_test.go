package core

// What non-uniform sample spacing does to the uniform Catmull-Rom curve.
//
// Written 2026-08-30 after both Pseudoregalia instances hard-crashed within two
// seconds of `curve catmull-rom` being switched on over a faulted link. The
// arithmetic in catmullRom() is fine; the assumption around it is not. curved()
// takes p0 and p3 by INDEX and treats every interval as equal, while a real
// session produces wildly unequal ones: 60Hz samples ~16ms apart, a keepalive
// re-send 250ms after the last change whenever a player stands still, plus
// whatever loss and reordering the link adds.
//
// The bound asserted here is deliberately generous. It does not ask the curve
// to be beautiful, only to stay in the neighbourhood of the segment it is
// filling -- a ghost thrown far outside that is a teleport, and this adapter
// renders ghosts as real pawns.

import (
	"math"
	"testing"
)

// worstExcursion renders the whole p1..p2 segment and returns how far outside
// the segment's own bounding box the curve ever goes, in multiples of the
// segment length.
func worstExcursion(b *remoteBuffer, i int) float64 {
	p1, p2 := b.snapshots[i], b.snapshots[i+1]
	segLen := math.Hypot(p2.Position[0]-p1.Position[0], p2.Position[1]-p1.Position[1])
	if segLen == 0 {
		segLen = 1
	}
	worst := 0.0
	for step := 0; step <= 100; step++ {
		rt := p1.Timestamp + (p2.Timestamp-p1.Timestamp)*int64(step)/100
		got := b.curved(i, rt)
		for j := 0; j < 2; j++ {
			lo := math.Min(p1.Position[j], p2.Position[j])
			hi := math.Max(p1.Position[j], p2.Position[j])
			out := math.Max(lo-got.Position[j], got.Position[j]-hi)
			if out/segLen > worst {
				worst = out / segLen
			}
		}
	}
	return worst
}

// Even spacing: the classic overshoot, small and documented.
func TestCurveOvershootIsSmallWhenSpacingIsEven(t *testing.T) {
	var b remoteBuffer
	b.add(at2D(1000, 0, 0))
	b.add(at2D(1016, 10, 0))
	b.add(at2D(1032, 20, 10))
	b.add(at2D(1048, 30, 30))

	if got := worstExcursion(&b, 1); got > 0.5 {
		t.Fatalf("evenly spaced samples overshot by %.2f segment lengths, want <= 0.5", got)
	}
}

// The real session's spacing: a keepalive re-send far behind, then dense
// samples once the player starts moving.
func TestCurveDoesNotTeleportWhenAKeepaliveSampleIsFarBehind(t *testing.T) {
	var b remoteBuffer
	b.add(at2D(1000, 0, 0))  // keepalive re-send: 250ms before the next one
	b.add(at2D(1250, 10, 0)) // player starts moving; 60Hz from here
	b.add(at2D(1266, 20, 10))
	b.add(at2D(1282, 30, 30))

	got := worstExcursion(&b, 1)
	t.Logf("worst excursion with a 250ms/16ms spacing mismatch: %.2f segment lengths", got)
	if got > 0.5 {
		t.Fatalf("uneven spacing threw the curve %.2f segment lengths outside the segment "+
			"(even spacing stays under 0.5) -- the uniform parameterisation is treating a "+
			"250ms gap as if it were 16ms", got)
	}
}

// The case the first test missed: constant velocity ACROSS the uneven gap.
// A player running at a steady speed sends a keepalive, then 60Hz samples once
// something changes. The points are collinear and evenly spaced in DISTANCE per
// unit time -- the motion could not be simpler -- but the intervals differ by
// 15x, and a uniform spline reads the far neighbour as if it were adjacent.
func TestCurveDoesNotOvershootAlongAStraightRunWithUnevenSpacing(t *testing.T) {
	var b remoteBuffer
	// 1 unit per millisecond, in a straight line. Timestamps are what differ.
	b.add(at2D(1000, 0, 0))   // 250ms before the next sample
	b.add(at2D(1250, 250, 0)) // from here, 60Hz
	b.add(at2D(1266, 266, 0))
	b.add(at2D(1282, 282, 0))

	got := worstExcursion(&b, 1)
	t.Logf("worst excursion on a straight constant-velocity run: %.2f segment lengths", got)
	if got > 0.5 {
		t.Fatalf("a STRAIGHT constant-velocity path was thrown %.2f segment lengths outside the "+
			"segment. The samples are collinear and the motion is uniform -- every bit of this is "+
			"the uniform parameterisation treating a 250ms interval as equal to a 16ms one", got)
	}
}
