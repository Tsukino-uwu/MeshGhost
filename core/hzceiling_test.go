package core

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// THE ACTUAL HIGH-RATE CEILING, MEASURED 2026-08-30 rather than derived.
//
// The question that produced this: "did anything degrade past 100Hz, or what is
// the safe limit?" Nothing above protocol.MaxSendHz (100) has ever been RUN --
// ClampSendHz prevents it -- so every claim about 144/256/480Hz was arithmetic
// from constants until this test existed.
//
// What it measures: fill the buffer at a rate, ask for a render time one
// interpolation delay in the past (the shipped render model), and check whether
// remoteBuffer.at() is interpolating or has fallen off the buffer's OLD EDGE and
// is edge-holding. Edge-holding is the silent failure -- no error anywhere, just
// a ghost that stutters, which is exactly how the 2026-08-28 bug presented when
// maxSnapshots was 8 and the dev rig ran 100Hz.
//
// THE RULE IT PINS: the buffer holds at most maxSnapshots (64) samples, so it
// spans 64/Hz seconds. Interpolation works while that span covers the
// interpolation delay -- so the ceiling is roughly 64/delay, and a LARGER delay
// breaks at a LOWER rate. maxSnapshotAgeMs (600) is the other bound and is what
// keeps the low rates honest.
//
// If maxSnapshots or maxSnapshotAgeMs changes, this test tells you the new
// ceiling instead of letting a silent stutter ship. Full write-up, including the
// bandwidth and timestamp axes: agent_docs/hz-ceiling.md.
func TestHighRateCeilingIsSetByTheSnapshotCount(t *testing.T) {
	cases := []struct {
		delayMs int64
		hz      int
		wantOK  bool // true = still interpolating, false = edge-held
	}{
		// The shipped delay. Clean well past MaxSendHz; breaks just under 256.
		{250, 20, true}, {250, 100, true}, {250, 144, true}, {250, 200, true},
		{250, 256, false}, {250, 480, false},
		// TEVI's measured delay buys headroom: a smaller delay needs less span.
		{175, 100, true}, {175, 256, true}, {175, 300, true}, {175, 480, false},
		// A larger delay breaks EARLIER -- the counter-intuitive half, and the
		// one that would bite someone raising interp to smooth a bad link.
		{400, 144, true}, {400, 200, false},
	}

	for _, tc := range cases {
		var b remoteBuffer
		step := 1000.0 / float64(tc.hz)
		n := tc.hz * 2 // two seconds, so the buffer is in steady state
		var last int64
		for i := 0; i < n; i++ {
			last = int64(float64(i) * step) // ms quantization, as it really happens
			b.add(protocol.State{
				Timestamp: last, AreaID: "a",
				Position: []float64{float64(i), 0, 0},
			})
		}
		renderTime := last - tc.delayMs
		if _, ok := b.at(renderTime); !ok {
			t.Fatalf("delay=%dms hz=%d: no state at all", tc.delayMs, tc.hz)
		}
		interpolating := renderTime >= b.snapshots[0].Timestamp
		if interpolating != tc.wantOK {
			verb := "edge-held"
			if interpolating {
				verb = "interpolated"
			}
			t.Errorf("delay=%dms hz=%d: %s, want interpolating=%v -- %d samples span %dms against a %dms delay. "+
				"If this changed deliberately, the high-rate ceiling moved: update this table AND agent_docs/scaling.md.",
				tc.delayMs, tc.hz, verb, tc.wantOK,
				len(b.snapshots), b.snapshots[len(b.snapshots)-1].Timestamp-b.snapshots[0].Timestamp, tc.delayMs)
		}
	}
}

// The floor half, for symmetry: maxSnapshotAgeMs (600) is what stops a LOW rate
// from holding a uselessly long history, and MinSendHz (10) sits inside it.
func TestLowRatesStayWithinTheAgeBound(t *testing.T) {
	var b remoteBuffer
	for i := 0; i < 40; i++ {
		b.add(protocol.State{Timestamp: int64(i) * 100, AreaID: "a", Position: []float64{float64(i)}}) // 10Hz
	}
	span := b.snapshots[len(b.snapshots)-1].Timestamp - b.snapshots[0].Timestamp
	if span > maxSnapshotAgeMs {
		t.Fatalf("buffer spans %dms, above maxSnapshotAgeMs (%d)", span, maxSnapshotAgeMs)
	}
	if _, ok := b.at(b.snapshots[len(b.snapshots)-1].Timestamp - 250); !ok {
		t.Fatal("10Hz with the shipped 250ms delay must still interpolate -- that is MinSendHz")
	}
}
