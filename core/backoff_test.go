package core

import (
	"testing"
	"time"
)

// TestBackoffDoublesAndClampsToItsOwnCeiling, not the shipped one: nextBackoffWithin serves two ceilings, and a clamp
// subtly wrong for one would only show as reconnects that feel wrong.
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

// TestUnconfiguredCoreKeepsTheShippedCadence: the fields exist so a test can compress them, and must not alter the
// shipped cadence while doing so.
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

// TestACeilingBelowTheFloorIsRaisedRatherThanInverted: clamped rather than rejected, because a timing knob refusing a
// session is worse than one being sensible.
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
