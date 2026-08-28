package core

import (
	"testing"
	"time"
)

// The doubling and the clamp, against a ceiling that is not the shipped one.
//
// Worth pinning separately from the reconnect itself: nextBackoffWithin is now used by two callers
// with two different ceilings, and a clamp that is subtly wrong for one of them would show up only
// as "reconnects feel wrong", which is not something anybody reports precisely.
func TestBackoffDoublesAndClampsToItsOwnCeiling(t *testing.T) {
	const max = 40 * time.Millisecond
	got := []time.Duration{}
	for cur := 10 * time.Millisecond; len(got) < 5; {
		cur = nextBackoffWithin(cur, max)
		got = append(got, cur)
	}
	want := []time.Duration{20, 40, 40, 40, 40}
	for i, w := range want {
		if got[i] != w*time.Millisecond {
			t.Fatalf("step %d: got %v, want %v (sequence %v)", i, got[i], w*time.Millisecond, got)
		}
	}
}

// A Core with no overrides must behave exactly as it always has.
//
// The point of making these fields was to let a TEST compress them, and a change that quietly
// altered the shipped cadence while doing so would be a much worse bug than the one it enables
// finding.
func TestUnconfiguredCoreKeepsTheShippedCadence(t *testing.T) {
	c := New()
	initial, max := c.reconnectBackoffBounds()
	if initial != InitialReconnectBackoff {
		t.Fatalf("initial backoff %v, want the shipped %v", initial, InitialReconnectBackoff)
	}
	if max != MaxReconnectBackoff {
		t.Fatalf("max backoff %v, want the shipped %v", max, MaxReconnectBackoff)
	}
}

func TestACoreUsesItsOwnBackoffBoundsWhenSet(t *testing.T) {
	c := New()
	c.ReconnectInitialBackoff = 5 * time.Millisecond
	c.ReconnectMaxBackoff = 20 * time.Millisecond

	initial, max := c.reconnectBackoffBounds()
	if initial != 5*time.Millisecond || max != 20*time.Millisecond {
		t.Fatalf("bounds are %v/%v, want 5ms/20ms", initial, max)
	}
}

// A ceiling below the floor is the one combination that reads as a bug rather than a setting: the
// first wait would be longer than the cap that is supposed to bound it. Clamped rather than
// rejected, because a timing knob refusing a session is worse than a timing knob being sensible.
func TestACeilingBelowTheFloorIsRaisedRatherThanInverted(t *testing.T) {
	c := New()
	c.ReconnectInitialBackoff = 30 * time.Millisecond
	c.ReconnectMaxBackoff = 10 * time.Millisecond

	initial, max := c.reconnectBackoffBounds()
	if max < initial {
		t.Fatalf("bounds inverted: initial %v, max %v", initial, max)
	}
	if next := nextBackoffWithin(initial, max); next < initial {
		t.Fatalf("backoff went BACKWARDS: %v -> %v", initial, next)
	}
}
