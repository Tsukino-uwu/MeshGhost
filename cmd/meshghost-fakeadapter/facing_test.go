package main

import (
	"encoding/json"
	"testing"
	"time"
)

// TestFacingFollowsPathSendsACardinalMatchingTheTangent: a 2D adapter reads facing from the orientation string, and
// a peer without one renders a static frame that looks like broken animation.
func TestFacingFollowsPathSendsACardinalMatchingTheTangent(t *testing.T) {
	a := &circleAdapter{
		start:         time.Now(),
		radiusUnits:   4,
		periodSeconds: 4,
		dims:          2,
		center:        []float64{10, 10},
		areaID:        "24/3",
		facingFollows: true,
	}

	// A quarter turn at a time must walk all four cardinals; a constant orientation fails.
	seen := map[string]int{}
	for q := 0; q < 4; q++ {
		st, ok := a.stateAt(time.Duration(q) * time.Second)
		if !ok {
			t.Fatalf("quarter %d: no state", q)
		}
		if len(st.Orientation) == 0 {
			t.Fatalf("quarter %d: no orientation sent", q)
		}
		var dir string
		if err := json.Unmarshal(st.Orientation, &dir); err != nil {
			t.Fatalf("quarter %d: orientation %q is not a JSON string: %v", q, st.Orientation, err)
		}
		switch dir {
		case "up", "down", "left", "right":
		default:
			t.Fatalf("quarter %d: orientation %q is not a cardinal a 2D adapter understands", q, dir)
		}
		seen[dir]++
	}
	if len(seen) != 4 {
		t.Fatalf("a full revolution sent %d distinct facings, want all 4: %v", len(seen), seen)
	}
}

// TestFacingFollowsPathIsOffByDefault: an adapter that gets an orientation starts trusting it, so existing rigs keep
// sending none.
func TestFacingFollowsPathIsOffByDefault(t *testing.T) {
	a := &circleAdapter{
		start:         time.Now(),
		radiusUnits:   4,
		periodSeconds: 4,
		dims:          2,
		center:        []float64{10, 10},
		areaID:        "24/3",
	}
	st, ok := a.stateAt(0)
	if !ok {
		t.Fatal("no state")
	}
	if len(st.Orientation) != 0 {
		t.Fatalf("orientation %q sent with -facing-follows-path off", st.Orientation)
	}
}
