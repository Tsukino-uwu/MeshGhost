package core

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The high-rate ceiling: were the snapshot count a functional bound, past some rate the buffer would span less than the
// interpolation delay and the ghost would edge-hold, silently. The window follows the render settings and the count
// bounds memory only.

// bufferFor fills a buffer at hz for two seconds with the window a Core running at this interpolation delay would give
// it, and reports whether a render time one delay in the past still falls inside the buffer.
func bufferFor(t *testing.T, hz int, delay time.Duration) (interpolating bool, samples int, spanMs int64) {
	t.Helper()
	c := New()
	c.InterpolationDelay = delay
	var b remoteBuffer
	b.historyMs = c.requiredHistoryMsLocked()

	step := 1000.0 / float64(hz)
	var last int64
	for i := 0; i < hz*2; i++ {
		last = int64(float64(i) * step) // ms quantization, as it really happens
		b.add(protocol.State{Timestamp: last, AreaID: "a", Position: []float64{float64(i), 0, 0}})
	}
	renderTime := last - delay.Milliseconds()
	if _, ok := b.at(renderTime); !ok {
		t.Fatalf("hz=%d delay=%v: no state at all", hz, delay)
	}
	return renderTime >= b.snapshots[0].Timestamp,
		len(b.snapshots),
		b.snapshots[len(b.snapshots)-1].Timestamp - b.snapshots[0].Timestamp
}

// TestHighRatesNoLongerEdgeHold: every case edge-held under a fixed snapshot count, so one coming back means the count
// has become a functional bound again.
func TestHighRatesNoLongerEdgeHold(t *testing.T) {
	cases := []struct {
		hz    int
		delay time.Duration
	}{
		{256, 250 * time.Millisecond}, // the first rate that broke at this delay
		{300, 250 * time.Millisecond},
		{480, 250 * time.Millisecond},
		{480, 175 * time.Millisecond}, // TEVI's measured delay
		{200, 400 * time.Millisecond}, // a large delay broke earliest, the counter-intuitive half
		{256, 400 * time.Millisecond},
	}
	for _, tc := range cases {
		ok, n, span := bufferFor(t, tc.hz, tc.delay)
		if !ok {
			t.Errorf("hz=%d delay=%v: EDGE-HELD -- %d samples spanning %dms against a %dms delay. "+
				"The snapshot count has become a functional bound again; interp.go says grow the WINDOW, not the count.",
				tc.hz, tc.delay, n, span, tc.delay.Milliseconds())
		}
	}
}

// TestALargeInterpolationDelayWorksAtAnyRate needs no high rate: a fixed window edge-holds every delay above it at
// every rate, so the window must follow the delay.
func TestALargeInterpolationDelayWorksAtAnyRate(t *testing.T) {
	for _, hz := range []int{20, 60, 100, 256} {
		for _, delay := range []time.Duration{700 * time.Millisecond, 1200 * time.Millisecond} {
			if ok, n, span := bufferFor(t, hz, delay); !ok {
				t.Errorf("hz=%d delay=%v: EDGE-HELD -- %d samples spanning %dms. The window must follow the delay.",
					hz, delay, n, span)
			}
		}
	}
}

// TestDerivedWindowNeverShrinksBelowTheOldFixedOne: whatever the settings, the derived window never falls below the old
// fixed one, so no working configuration regresses.
func TestDerivedWindowNeverShrinksBelowTheOldFixedOne(t *testing.T) {
	for _, delay := range []time.Duration{0, 50 * time.Millisecond, 250 * time.Millisecond} {
		c := New()
		c.InterpolationDelay = delay
		if got := c.requiredHistoryMsLocked(); got < defaultSnapshotAgeMs {
			t.Errorf("delay=%v: window %dms is below the old fixed %dms", delay, got, defaultSnapshotAgeMs)
		}
	}
}

// TestBothBoundsStillBound: the count still bounds memory, and the derived window has its own ceiling, so a mistyped
// delay cannot grow the buffer without end.
func TestBothBoundsStillBound(t *testing.T) {
	c := New()
	c.InterpolationDelay = time.Hour
	c.Extrapolate = time.Hour
	if got := c.requiredHistoryMsLocked(); got != maxHistoryMs {
		t.Errorf("an absurd delay produced a %dms window, want it capped at %dms", got, maxHistoryMs)
	}

	// A sender far faster than anything configurable must still be capped.
	var b remoteBuffer
	b.historyMs = maxHistoryMs
	for i := 0; i < maxSnapshots*3; i++ {
		b.add(protocol.State{Timestamp: int64(i), AreaID: "a", Position: []float64{float64(i)}}) // 1000Hz
	}
	if len(b.snapshots) > maxSnapshots {
		t.Fatalf("buffer grew to %d snapshots, above the memory bound %d", len(b.snapshots), maxSnapshots)
	}
}

// TestLowRatesStillInterpolate: the floor, MinSendHz with a 250ms delay, still interpolates.
func TestLowRatesStillInterpolate(t *testing.T) {
	if ok, n, span := bufferFor(t, 10, 250*time.Millisecond); !ok {
		t.Fatalf("10Hz (MinSendHz) with the shipped 250ms delay edge-held -- %d samples spanning %dms", n, span)
	}
}
