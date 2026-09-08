package core

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestAnAbsurdSaveLastSpanIsClampedNotHeldWhole is review G8 (2026-09-08).
//
// replay.save_last was the one duration in the config with no ceiling: setSpan
// took it with a `> 0` check while remote history is clamped at maxHistoryMs and
// chaser depth at maxChaserBehind. "save_last": "6h" asked the ring to hold
// 2.16 million protocol.State values at the 100Hz the tap is fed at, for the
// whole session, and the player's core grew all evening with no line saying why.
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

// TestTheRingDropsSamplesOlderThanTheClamp proves the clamp does the thing it
// exists for rather than merely setting a field: samples older than maxRingSpan
// must actually leave the buffer. Written against the ring directly, because
// feeding six hours of real samples through the tap is not a test.
func TestTheRingDropsSamplesOlderThanTheClamp(t *testing.T) {
	var r sampleRing
	r.setSpan(6 * time.Hour)

	// One sample an hour for eight hours, stamped in the ring's own ms domain.
	const hourMs = int64(60 * 60 * 1000)
	for i := int64(0); i < 8; i++ {
		r.add(protocol.State{Timestamp: i * hourMs})
	}
	got := r.snapshot()
	// With the clamp at 10 minutes, hourly samples means only the newest
	// survives; without it, a 6h span would hold seven of the eight.
	if len(got) != 1 {
		t.Fatalf("the ring holds %d hourly samples, want 1 -- a 6h span was taken as-is", len(got))
	}
	if got[0].Timestamp != 7*hourMs {
		t.Fatalf("the ring kept the sample at %dms, want the newest at %dms", got[0].Timestamp, 7*hourMs)
	}
}

// TestASaneSaveLastSpanIsUntouched: the clamp must be a ceiling and nothing
// else. The shipped default and every value a player realistically types pass
// through exactly as written.
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
