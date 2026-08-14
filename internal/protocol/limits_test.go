package protocol

import (
	"math"
	"testing"
)

// TestIsValidPosition covers the newest safety check added to this
// package — found with zero test coverage anywhere in the codebase while
// doing a full documentation/code sweep, despite being the check that
// stops a peer wedging a NaN/±Inf/absurd-magnitude value onto the wire.
func TestIsValidPosition(t *testing.T) {
	cases := []struct {
		name string
		pos  []float64
		want bool
	}{
		{"empty", nil, true},
		{"ordinary", []float64{1, 2, 3}, true},
		{"at max bound", []float64{MaxPositionComponent, -MaxPositionComponent}, true},
		{"just past max bound", []float64{MaxPositionComponent + 1}, false},
		{"NaN", []float64{math.NaN()}, false},
		{"+Inf", []float64{math.Inf(1)}, false},
		{"-Inf", []float64{math.Inf(-1)}, false},
		{"one bad component among good ones", []float64{1, math.NaN(), 2}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsValidPosition(tc.pos); got != tc.want {
				t.Errorf("IsValidPosition(%v) = %v, want %v", tc.pos, got, tc.want)
			}
		})
	}
}

// TestValidateState covers the extracted, shared check that replaced the
// verbatim-duplicated validation block previously carried separately by
// internal/relay and internal/core.
func TestValidateState(t *testing.T) {
	valid := func() State {
		return State{
			PlayerID: "p1",
			AreaID:   "a",
			Position: []float64{1, 2},
			Anim:     "idle",
		}
	}

	if !ValidateState(valid()) {
		t.Fatal("a valid state was rejected")
	}

	t.Run("oversized position", func(t *testing.T) {
		st := valid()
		st.Position = make([]float64, MaxPositionLen+1)
		if ValidateState(st) {
			t.Fatal("oversized position was accepted")
		}
	})
	t.Run("oversized extras", func(t *testing.T) {
		st := valid()
		st.Extras = map[string]any{"junk": string(make([]byte, MaxExtrasBytes+1))}
		if ValidateState(st) {
			t.Fatal("oversized extras was accepted")
		}
	})
	t.Run("oversized area_id", func(t *testing.T) {
		st := valid()
		st.AreaID = string(make([]byte, MaxAreaIDLen+1))
		if ValidateState(st) {
			t.Fatal("oversized area_id was accepted")
		}
	})
	t.Run("oversized anim", func(t *testing.T) {
		st := valid()
		st.Anim = string(make([]byte, MaxAnimLen+1))
		if ValidateState(st) {
			t.Fatal("oversized anim was accepted")
		}
	})
	t.Run("oversized orientation", func(t *testing.T) {
		st := valid()
		st.Orientation = make([]byte, MaxOrientationBytes+1)
		if ValidateState(st) {
			t.Fatal("oversized orientation was accepted")
		}
	})
	t.Run("non-finite position", func(t *testing.T) {
		st := valid()
		st.Position = []float64{math.NaN()}
		if ValidateState(st) {
			t.Fatal("non-finite position was accepted")
		}
	})
}
