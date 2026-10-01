package core

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestAnAbsurdSaveLastSpanIsClampedNotHeldWhole: save_last has a ceiling, as remote history (maxHistoryMs) and
// chaser depth (maxChaserBehind) do.
func TestAnAbsurdSaveLastSpanIsClampedNotHeldWhole(t *testing.T) {
	c := New()
	c.SaveLastSpan = 6 * time.Hour
	c.armRing()

	c.ring.mu.Lock()
	span := c.ring.span
	c.ring.mu.Unlock()
	if want := maxRingSpan.Milliseconds(); span != want {
		t.Fatalf("the ring kept a span of %dms for a 6h save_last, want %dms (maxRingSpan) -- an unbounded buffer", span, want)
	}
}

// TestTheRingDropsSamplesOlderThanTheClamp: the clamp must drop older samples, not merely set a field. Run against the
// ring directly, since six hours of samples through the tap is not a test.
func TestTheRingDropsSamplesOlderThanTheClamp(t *testing.T) {
	var r sampleRing
	r.setSpan(6 * time.Hour)

	// One sample an hour for eight hours, stamped in the ring's own ms domain.
	const hourMs = int64(60 * 60 * 1000)
	for i := int64(0); i < 8; i++ {
		r.add(protocol.State{Timestamp: i * hourMs})
	}
	got := r.snapshot()
	// With the clamp at 10 minutes only the newest hourly sample survives; a 6h span would hold seven of the eight.
	if len(got) != 1 {
		t.Fatalf("the ring holds %d hourly samples, want 1 -- a 6h span was taken as-is", len(got))
	}
	if got[0].Timestamp != 7*hourMs {
		t.Fatalf("the ring kept the sample at %dms, want the newest at %dms", got[0].Timestamp, 7*hourMs)
	}
}

// TestASaneSaveLastSpanIsUntouched: the shipped default and every value a player realistically types pass through.
func TestASaneSaveLastSpanIsUntouched(t *testing.T) {
	for _, span := range []time.Duration{time.Second, 30 * time.Second, 2 * time.Minute, maxRingSpan} {
		c := New()
		c.SaveLastSpan = span
		c.armRing()
		c.ring.mu.Lock()
		got := c.ring.span
		c.ring.mu.Unlock()
		if got != span.Milliseconds() {
			t.Errorf("save_last %s became %dms; a ceiling must not touch a value under it", span, got)
		}
	}
}
