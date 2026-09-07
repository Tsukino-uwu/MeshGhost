package protocol

import (
	"math"
	"strings"
	"testing"
	"time"
)

// State.Timestamp was the one field on a state that nothing bounded anywhere --
// not here, not in the relay, not in the core. See MaxTimestampMs for the three
// separate defects that produced.
//
// The property that matters is arithmetic, not taste: the widest span between
// two ACCEPTED timestamps must not overflow a time.Duration, because both the
// replay player and the interpolator convert a difference of them to one.
func TestTimestampIsBounded(t *testing.T) {
	base := State{PlayerID: "p1", AreaID: "a", Position: []float64{1, 2}}

	valid := func(ts int64) State { s := base; s.Timestamp = ts; return s }

	for _, tc := range []struct {
		name string
		ts   int64
		want bool
	}{
		{"a real unix millisecond timestamp", 1_780_000_000_000, true},
		{"zero", 0, true},
		{"the cap itself", MaxTimestampMs, true},
		{"one past the cap", MaxTimestampMs + 1, false},
		{"negative", -1, false},
		{"the value that overflowed sleepUntil", 10_000_000_000_000, false},
		{"int64 max", math.MaxInt64, false},
		{"int64 min", math.MinInt64, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := ValidateState(valid(tc.ts)); got != tc.want {
				t.Fatalf("ValidateState(timestamp=%d) = %v, want %v", tc.ts, got, tc.want)
			}
			reason := StateRejectReason(valid(tc.ts))
			if tc.want && reason != "" {
				t.Fatalf("a valid timestamp reported a reject reason: %q", reason)
			}
			if !tc.want && !strings.Contains(reason, "timestamp") {
				t.Fatalf("StateRejectReason = %q, want it to name the timestamp", reason)
			}
		})
	}
}

// The bound exists to make this conversion safe, so assert the conversion
// rather than the constant: a future edit that widens MaxTimestampMs without
// re-checking the arithmetic fails here rather than in a spinning goroutine on
// somebody's machine.
func TestTheWidestValidTimestampSpanFitsADuration(t *testing.T) {
	// Both ends are accepted values, so this is the worst case a caller can be
	// handed after validation.
	widest := int64(MaxTimestampMs) - 0
	d := time.Duration(widest) * time.Millisecond
	if d <= 0 {
		t.Fatalf("the widest valid span (%d ms) overflowed time.Duration and came out %v -- "+
			"a negative duration makes time.After fire immediately, which is the replay "+
			"spin this bound exists to prevent", widest, d)
	}
	if got := int64(d / time.Millisecond); got != widest {
		t.Fatalf("round trip through time.Duration changed %d ms into %d ms", widest, got)
	}
}
