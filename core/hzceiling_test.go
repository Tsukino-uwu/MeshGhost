package core

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// THE HIGH-RATE CEILING. Measured 2026-08-30, then FIXED the same day.
//
// The question that produced this: "did anything degrade past 100Hz, or what is
// the safe limit?" Nothing above protocol.MaxSendHz (100) had ever been RUN --
// ClampSendHz prevents it -- so every claim about 144/256/480Hz was arithmetic
// until this test existed. Measuring it found a real cliff, and the cliff was
// ours rather than a law of nature: maxSnapshots was a functional bound wearing
// a memory bound's clothes. See interp.go's comment above maxSnapshots.
//
// BEFORE THE FIX (kept because it is the regression this defends against):
//
//	interp 175ms: interpolated to 300Hz, EDGE-HELD at 480Hz
//	interp 250ms: interpolated to 200Hz, EDGE-HELD at 256Hz   <- shipped setting
//	interp 400ms: interpolated to 144Hz, EDGE-HELD at 200Hz
//
// Silent every time -- no error, just a ghost that stutters, exactly how the
// 2026-08-28 bug presented when the count was 8 and the dev rig ran 100Hz.
//
// AFTER THE FIX every one of those interpolates, because the window is derived
// from the render settings and the count is memory-only. agent_docs/hz-ceiling.md.

// bufferFor fills a buffer at hz for two seconds with the window a Core running
// at this interpolation delay would give it, and reports whether a render time
// one delay in the past still falls inside the buffer.
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

// TestHighRatesNoLongerEdgeHold is the fix, stated as the three cases that
// failed before it. Every one of these edge-held on 2026-08-30 and must not
// again: if one comes back, the count has been made functional a second time.
func TestHighRatesNoLongerEdgeHold(t *testing.T) {
	cases := []struct {
		hz    int
		delay time.Duration
	}{
		{256, 250 * time.Millisecond}, // the shipped delay, first rate that broke
		{300, 250 * time.Millisecond},
		{480, 250 * time.Millisecond},
		{480, 175 * time.Millisecond}, // TEVI's measured delay
		{200, 400 * time.Millisecond}, // a LARGE delay broke EARLIEST -- the counter-intuitive half
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

// The second bug the same constant hid, and it needs no high rate at all: a
// fixed 600ms window meant any interpolation delay above it edge-held at EVERY
// rate, including the shipped 20Hz.
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

// The window must never SHRINK below what shipped, whatever the settings --
// this fix must not be able to regress a working configuration.
func TestDerivedWindowNeverShrinksBelowTheOldFixedOne(t *testing.T) {
	for _, delay := range []time.Duration{0, 50 * time.Millisecond, 250 * time.Millisecond} {
		c := New()
		c.InterpolationDelay = delay
		if got := c.requiredHistoryMsLocked(); got < defaultSnapshotAgeMs {
			t.Errorf("delay=%v: window %dms is below the old fixed %dms", delay, got, defaultSnapshotAgeMs)
		}
	}
}

// And both bounds still bound. The count is memory-only now, but "only memory"
// is not "no limit", and the derived window has its own ceiling so a mistyped
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

// The floor: MinSendHz with the shipped delay must still interpolate.
func TestLowRatesStillInterpolate(t *testing.T) {
	if ok, n, span := bufferFor(t, 10, 250*time.Millisecond); !ok {
		t.Fatalf("10Hz (MinSendHz) with the shipped 250ms delay edge-held -- %d samples spanning %dms", n, span)
	}
}
