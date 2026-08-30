package core

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func TestRemoteBufferEmpty(t *testing.T) {
	var b remoteBuffer
	if _, ok := b.at(1000); ok {
		t.Fatal("at() on empty buffer returned ok=true")
	}
}

func TestRemoteBufferSingleSnapshotSnaps(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{PlayerID: "p2", Timestamp: 1000, Position: []float64{5, 5}, AreaID: "a", Anim: "idle"})

	got, ok := b.at(5000)
	if !ok {
		t.Fatal("at() returned ok=false")
	}
	if got.Position[0] != 5 || got.Position[1] != 5 {
		t.Fatalf("position = %v, want [5 5] (single snapshot, no extrapolation)", got.Position)
	}
}

func TestRemoteBufferInterpolatesBetweenSnapshots(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{PlayerID: "p2", Timestamp: 1000, Position: []float64{0, 0}, AreaID: "a", Anim: "walking"})
	b.add(protocol.State{PlayerID: "p2", Timestamp: 2000, Position: []float64{10, 20}, AreaID: "a", Anim: "walking"})

	got, ok := b.at(1500)
	if !ok {
		t.Fatal("at() returned ok=false")
	}
	if got.Position[0] != 5 || got.Position[1] != 10 {
		t.Fatalf("position at midpoint = %v, want [5 10]", got.Position)
	}
	if got.Timestamp != 1500 {
		t.Fatalf("timestamp = %d, want 1500", got.Timestamp)
	}
	if got.AreaID != "a" || got.Anim != "walking" {
		t.Fatalf("opaque fields = %q/%q, want unchanged from older snapshot", got.AreaID, got.Anim)
	}
}

func TestRemoteBufferOpaqueFieldsHoldFromOlderSnapshot(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{PlayerID: "p2", Timestamp: 1000, Position: []float64{0}, Anim: "idle"})
	b.add(protocol.State{PlayerID: "p2", Timestamp: 2000, Position: []float64{10}, Anim: "running"})

	got, _ := b.at(1999)
	if got.Anim != "idle" {
		t.Fatalf("anim = %q, want %q (holds until the newer sample's timestamp is reached)", got.Anim, "idle")
	}
}

func TestRemoteBufferClampsBeforeFirstAndAfterLast(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{PlayerID: "p2", Timestamp: 1000, Position: []float64{1}})
	b.add(protocol.State{PlayerID: "p2", Timestamp: 2000, Position: []float64{2}})

	before, _ := b.at(0)
	if before.Position[0] != 1 {
		t.Fatalf("before first snapshot: position = %v, want [1] (clamp, no extrapolation)", before.Position)
	}

	after, _ := b.at(999999)
	if after.Position[0] != 2 {
		t.Fatalf("after last snapshot: position = %v, want [2] (clamp, no extrapolation)", after.Position)
	}
}

func TestRemoteBufferEvictsOldSnapshots(t *testing.T) {
	// Eviction is by TIME first (2026-08-28): a bare count starved a large
	// interpolation delay at a high send rate -- 8 samples at 100Hz is 80ms of
	// history, so a 250ms render time fell off the old edge and edge-held,
	// seen on screen as stutter on long walks. History must cover the buffer's
	// window regardless of rate.
	//
	// A bare remoteBuffer has historyMs unset, which means defaultSnapshotAgeMs
	// -- the same 600ms this test was written against. Since 2026-08-30 a Core
	// DERIVES the window from its render settings instead (Core.requiredHistoryMsLocked),
	// because the fixed value hid two silent edge-hold bugs; see
	// core/hzceiling_test.go. This test still pins the default path.
	var b remoteBuffer
	for i := 0; i < 69; i++ {
		b.add(protocol.State{PlayerID: "p2", Timestamp: int64(i * 100), Position: []float64{float64(i)}})
	}
	// Newest is t=6800; everything older than 6800-600 is gone.
	want := 1 + defaultSnapshotAgeMs/100
	if len(b.snapshots) != want {
		t.Fatalf("buffer length = %d, want %d (a %dms window at 100ms spacing)", len(b.snapshots), want, defaultSnapshotAgeMs)
	}
	if b.snapshots[0].Position[0] != 62 {
		t.Fatalf("oldest retained snapshot position = %v, want [62]", b.snapshots[0].Position)
	}

	// The count cap still exists, and since 2026-08-30 it is reachable ONLY by
	// an adversarially fast sender -- which is the whole point of the change.
	// 5ms spacing (200Hz) used to trip it and now does not, because 1024
	// samples at 200Hz would be five seconds of history and the 600ms window
	// trims them first. Reaching it takes MORE THAN ONE SAMPLE PER MILLISECOND,
	// which no configurable rate can produce (MaxSendHz is 100).
	var dense remoteBuffer
	for i := 0; i < maxSnapshots+6; i++ {
		dense.add(protocol.State{PlayerID: "p2", Timestamp: int64(i / 2), Position: []float64{float64(i)}})
	}
	if len(dense.snapshots) != maxSnapshots {
		t.Fatalf("dense buffer length = %d, want the %d count cap", len(dense.snapshots), maxSnapshots)
	}

	// And at a rate a real relay could actually advertise, the WINDOW governs
	// and the count never gets a say -- the property the fix exists to give.
	var fast remoteBuffer
	for i := 0; i < 2000; i++ {
		fast.add(protocol.State{PlayerID: "p2", Timestamp: int64(i * 5), Position: []float64{float64(i)}}) // 200Hz
	}
	if wantFast := 1 + defaultSnapshotAgeMs/5; len(fast.snapshots) != wantFast {
		t.Fatalf("200Hz buffer holds %d snapshots, want %d (a %dms window at 5ms spacing) -- "+
			"if this is %d, the count has become a functional bound again",
			len(fast.snapshots), wantFast, defaultSnapshotAgeMs, maxSnapshots)
	}
}

func TestRemoteBufferMismatchedPositionLengthFallsBackToOlder(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{PlayerID: "p2", Timestamp: 1000, Position: []float64{1, 2}})
	b.add(protocol.State{PlayerID: "p2", Timestamp: 2000, Position: []float64{1, 2, 3}})

	got, _ := b.at(1500)
	if len(got.Position) != 2 || got.Position[0] != 1 || got.Position[1] != 2 {
		t.Fatalf("position = %v, want [1 2] (fallback to older on length mismatch)", got.Position)
	}
}

// TestRemoteBufferMismatchedAreaIDFallsBackToOlder is a regression test for
// a bug found in a review pass: without an AreaID check, lerp blended two
// bracketing snapshots' raw world coordinates even when they belonged to
// different areas (a remote crossing a zone boundary mid-interpolation-
// window), rendering at a meaningless midpoint between two unrelated
// coordinate spaces — the same phantom-ghost failure the cross-area
// filtering ADR (agent_docs/architecture.md) exists to prevent, just
// reached via a different path than the one that ADR actually closed.
func TestRemoteBufferMismatchedAreaIDFallsBackToOlder(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{PlayerID: "p2", Timestamp: 1000, Position: []float64{1, 2}, AreaID: "zone-a"})
	b.add(protocol.State{PlayerID: "p2", Timestamp: 2000, Position: []float64{100, 200}, AreaID: "zone-b"})

	got, _ := b.at(1500)
	if got.AreaID != "zone-a" || got.Position[0] != 1 || got.Position[1] != 2 {
		t.Fatalf("state = %+v, want unchanged from older snapshot (zone-a, [1 2]) on an area_id change between bracketing snapshots", got)
	}
}

// TestOpaqueFieldsNeverFlapAcrossInterpolation is the Go side's answer to a
// question raised by a live session: a Pseudoregalia ghost was seen entering
// and leaving its slide pose repeatedly during one continuous player slide,
// and the adapter fires that pose on the EDGE of an opaque value it receives
// (the peer's capsule height crossing a standing threshold). So the question
// was whether interpolation could manufacture those edges.
//
// It cannot, and this pins that: non-position fields come from the OLDER of
// the two bracketing snapshots, and renderTime advances monotonically, so a
// value that changes once in the source changes once in the output. Anything
// else would mean the core was inventing state transitions in a field it is
// forbidden to interpret at all.
func TestOpaqueFieldsNeverFlapAcrossInterpolation(t *testing.T) {
	// A peer that stands, then crouches once and stays crouched — the shape a
	// held slide should produce.
	const standing, crouched = 65.0, 22.0
	// Kept inside maxSnapshots so nothing is trimmed: the invariant is about
	// interpolation, and a buffer that dropped the standing samples would
	// report "no transitions" for a reason that has nothing to do with it.
	const samples = 8
	var b remoteBuffer
	for i := 0; i < samples; i++ {
		half := standing
		if i >= 4 {
			half = crouched
		}
		b.add(protocol.State{
			Timestamp: int64(1000 + i*50),
			AreaID:    "zone",
			Position:  []float64{float64(i), 0, 0},
			Anim:      "slide",
			Extras:    map[string]any{"capsule_half": half},
		})
	}

	// Walk the render clock forward one millisecond at a time across the whole
	// buffer and count how many times the opaque value changes.
	transitions := 0
	last := -1.0
	for rt := int64(1000); rt <= 1000+(samples-1)*50; rt++ {
		st, ok := b.at(rt)
		if !ok {
			t.Fatalf("no state at renderTime %d", rt)
		}
		got, isFloat := st.Extras["capsule_half"].(float64)
		if !isFloat {
			t.Fatalf("opaque value came back as %T, not the float64 that went in", st.Extras["capsule_half"])
		}
		if last >= 0 && got != last {
			transitions++
		}
		last = got
	}
	if transitions != 1 {
		t.Fatalf("an opaque value that changed ONCE in the source changed %d times across "+
			"interpolation — the core is manufacturing edges in a field it must not interpret",
			transitions)
	}
	if last != crouched {
		t.Fatalf("final opaque value = %v, want %v", last, crouched)
	}
}
