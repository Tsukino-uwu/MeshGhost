package core

import (
	"testing"

	"meshghost/internal/protocol"
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
	var b remoteBuffer
	for i := 0; i < maxSnapshots+5; i++ {
		b.add(protocol.State{PlayerID: "p2", Timestamp: int64(i * 100), Position: []float64{float64(i)}})
	}
	if len(b.snapshots) != maxSnapshots {
		t.Fatalf("buffer length = %d, want %d", len(b.snapshots), maxSnapshots)
	}
	if b.snapshots[0].Position[0] != 5 {
		t.Fatalf("oldest retained snapshot position = %v, want [5] (first 5 evicted)", b.snapshots[0].Position)
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
