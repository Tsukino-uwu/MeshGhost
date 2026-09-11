package main

import (
	"math"
	"testing"
	"time"
)

// THE SYNTHETIC PEER HAS TO STOP, or this rig cannot judge an interpolator
// (review H15).
//
// A constant-speed circle is the most flattering input an interpolator can be
// given: no stops, no turns, no landings, infinitely differentiable, sampled
// exactly on the tick. Every prediction is right and every correction is zero --
// and `dev-scripts/README.md`'s own rule is that you judge an interpolator on
// the CORRECTION. A ladder climbed against a circle cannot see the thing it is
// climbing for.
//
// A stop is the one discontinuity a real player produces constantly and a circle
// never does: velocity to zero and back, which is where an extrapolating
// interpolator overshoots and has to pull back.
func TestTheSyntheticPeerActuallyStops(t *testing.T) {
	a := &circleAdapter{
		radiusUnits:   100,
		periodSeconds: 4,
		dims:          2,
		center:        []float64{0, 0},
		stopPeriod:    2,
		stopFraction:  0.5, // half of every 2 s standing still
	}

	// Sample a whole stop period finely and measure how much of it was spent
	// not moving.
	const step = 10 * time.Millisecond
	var still, moved int
	var prev []float64
	for elapsed := time.Duration(0); elapsed < 2*time.Second; elapsed += step {
		st, ok := a.stateAt(elapsed)
		if !ok {
			t.Fatal("stateAt refused a sample")
		}
		if prev != nil {
			d := math.Hypot(st.Position[0]-prev[0], st.Position[1]-prev[1])
			if d < 1e-9 {
				still++
			} else {
				moved++
			}
		}
		prev = append(prev[:0], st.Position...)
	}
	if still == 0 {
		t.Fatal("the synthetic peer never stopped -- this is the constant-speed circle again, " +
			"and every prediction against it is right by construction")
	}
	if moved == 0 {
		t.Fatal("the synthetic peer never moved at all")
	}
	// Half the period, within a couple of samples.
	share := float64(still) / float64(still+moved)
	if share < 0.4 || share > 0.6 {
		t.Fatalf("the peer was still for %.0f%% of the period, want about 50%%", share*100)
	}
}

// AND IT RESUMES WHERE IT STOPPED. The stop drives the ANGLE'S clock rather than
// the angle, so a resume continues the path -- if it jumped to where it would
// have been, the rig would be injecting a teleport, which is a different test
// and one the core currently cannot tell from a walk (ideas.md, review E11).
func TestAStoppedPeerResumesWhereItStopped(t *testing.T) {
	a := &circleAdapter{
		radiusUnits:   100,
		periodSeconds: 4,
		dims:          2,
		center:        []float64{0, 0},
		stopPeriod:    2,
		stopFraction:  0.5,
	}

	// The last sample before the stop ends, and the first after.
	before, _ := a.stateAt(1990 * time.Millisecond)
	after, _ := a.stateAt(2010 * time.Millisecond)
	jump := math.Hypot(after.Position[0]-before.Position[0], after.Position[1]-before.Position[1])

	// One tick of ordinary movement, for scale.
	m0, _ := a.stateAt(10 * time.Millisecond)
	m1, _ := a.stateAt(30 * time.Millisecond)
	oneStep := math.Hypot(m1.Position[0]-m0.Position[0], m1.Position[1]-m0.Position[1])

	if jump > oneStep*3 {
		t.Fatalf("resuming moved %.2f units where an ordinary step is %.2f -- the peer is "+
			"TELEPORTING out of its stop rather than continuing its path", jump, oneStep)
	}
}

// OFF IS STILL AVAILABLE, and it has to be: every measurement taken before
// 2026-09-11 was against the always-moving circle, so a comparison against one
// of those needs the old shape back.
func TestStopsCanBeTurnedOff(t *testing.T) {
	a := &circleAdapter{
		radiusUnits:   100,
		periodSeconds: 4,
		dims:          2,
		center:        []float64{0, 0},
		stopPeriod:    0,
	}
	var prev []float64
	for elapsed := time.Duration(0); elapsed < 3*time.Second; elapsed += 20 * time.Millisecond {
		st, _ := a.stateAt(elapsed)
		if prev != nil {
			if math.Hypot(st.Position[0]-prev[0], st.Position[1]-prev[1]) < 1e-9 {
				t.Fatal("the peer stopped with -stop-every 0, which is meant to restore the " +
					"always-moving circle every earlier measurement was taken against")
			}
		}
		prev = append(prev[:0], st.Position...)
	}
}
