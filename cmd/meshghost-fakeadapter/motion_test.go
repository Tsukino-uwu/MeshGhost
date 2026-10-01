package main

import (
	"math"
	"testing"
	"time"
)

// TestTheSyntheticPeerActuallyStops: against a constant-speed circle every prediction is right, while a stop is where
// an extrapolating interpolator overshoots and has to correct.
func TestTheSyntheticPeerActuallyStops(t *testing.T) {
	a := &circleAdapter{
		radiusUnits:   100,
		periodSeconds: 4,
		dims:          2,
		center:        []float64{0, 0},
		stopPeriod:    2,
		stopFraction:  0.5, // half of every 2 s standing still
	}

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
	share := float64(still) / float64(still+moved)
	if share < 0.4 || share > 0.6 {
		t.Fatalf("the peer was still for %.0f%% of the period, want about 50%%", share*100)
	}
}

// TestAStoppedPeerResumesWhereItStopped: a stop pauses the angle's clock, so a resume continues the path; a jump to
// where it would have been is a teleport, a different test.
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

// TestStopsCanBeTurnedOff: -stop-every 0 restores the always-moving circle that earlier measurements were taken
// against.
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
