package main

import (
	"encoding/json"
	"testing"
	"time"
)

// A 2D tile game's adapter reads a peer's facing from the orientation
// STRING ("up"/"down"/"left"/"right"), and Crystal's drawn tier keys its
// walk animation off it too -- a peer with no orientation renders a static
// forward-facing frame, which looks exactly like broken animation. So the
// rig has to be able to send one, and it has to follow the path the peer is
// actually walking rather than being a constant.
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

	// A counter-clockwise circle's tangent leads the radius by 90 degrees, so
	// stepping a quarter turn at a time must walk the four cardinals in order
	// and never repeat one -- a constant orientation passes neither check.
	seen := map[string]int{}
	for q := 0; q < 4; q++ {
		// stateAt is deterministic in elapsed time; a quarter period is a
		// quarter turn.
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

// Off by default: every existing rig sends no orientation for a 2D game and
// must keep doing so, since an adapter that gets one starts trusting it.
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
