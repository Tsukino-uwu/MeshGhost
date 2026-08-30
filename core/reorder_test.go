package core

// Samples that arrive OUT OF ORDER, which the state plane can always produce:
// it travels on unreliable datagrams by design (contract.md -- lossy,
// latest-wins), and datagrams reorder.
//
// Found live 2026-08-28, the first time a session was run through
// meshghost-netsim with real loss and reordering rather than over a perfect
// loopback. The buffer appended blindly and its own comment said callers were
// expected to deliver samples in order -- an assumption nothing enforced and
// the network does not honour. Out of order, at() brackets a render time with
// the wrong pair and the ghost jumps backwards and forwards: the user's read
// was "kinda snap/teleport around a bit".

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func ts(t int64, x float64) protocol.State {
	return protocol.State{AreaID: "a", Anim: "walk", Position: []float64{x, 0}, Timestamp: t}
}

func TestOutOfOrderSamplesStillRenderMonotonically(t *testing.T) {
	var b remoteBuffer
	// A peer walking steadily right, with the middle sample overtaken by the
	// one after it -- the ordinary shape of a reordered datagram pair.
	b.add(ts(1000, 0))
	b.add(ts(1100, 10))
	b.add(ts(1300, 30))
	b.add(ts(1200, 20)) // arrives late, belongs between the two above

	var prev float64 = -1
	for rt := int64(1000); rt <= 1300; rt += 10 {
		got, ok := b.at(rt)
		if !ok {
			t.Fatalf("no state at %d", rt)
		}
		if got.Position[0] < prev {
			t.Fatalf("at %d the ghost moved BACKWARDS to x=%v from x=%v -- a reordered sample is bracketing wrongly",
				rt, got.Position[0], prev)
		}
		prev = got.Position[0]
	}

	// And the late sample is genuinely being used, not merely tolerated:
	// halfway between 1200 and 1300 is x=25.
	got, _ := b.at(1250)
	if got.Position[0] != 25 {
		t.Fatalf("at 1250 the ghost is at x=%v, want 25 -- the reordered sample was dropped rather than placed", got.Position[0])
	}
}

// A sample so late that the window has already moved past it can only drag a
// ghost backwards, so it is dropped rather than inserted.
func TestAHopelesslyLateSampleIsDropped(t *testing.T) {
	var b remoteBuffer
	for i := 0; i < maxSnapshots; i++ {
		b.add(ts(2000+int64(i)*50, float64(i)*5))
	}
	newestBefore := b.newestTimestamp()
	oldestBefore := b.snapshots[0].Timestamp

	b.add(ts(1000, -999)) // from long before anything held

	if b.snapshots[0].Timestamp != oldestBefore {
		t.Fatalf("oldest snapshot became %d, want %d -- a hopelessly late sample was inserted",
			b.snapshots[0].Timestamp, oldestBefore)
	}
	if b.newestTimestamp() != newestBefore {
		t.Fatalf("newest snapshot changed to %d, want %d", b.newestTimestamp(), newestBefore)
	}
	for _, s := range b.snapshots {
		if s.Position[0] == -999 {
			t.Fatal("the late sample is in the buffer -- it can only pull a ghost backwards")
		}
	}
}

// The ordinary in-order case must be untouched by all of the above, including
// the eviction of the oldest once the window is full.
func TestInOrderSamplesAreUnaffected(t *testing.T) {
	var b remoteBuffer
	const n = maxSnapshots + 6
	for i := 0; i < n; i++ {
		b.add(ts(1000+int64(i)*5, float64(i)))
	}
	// The WINDOW governs here, not the count. This assertion used to read
	// maxSnapshots: at 5ms spacing (200Hz) the old 64-sample cap trimmed to 64
	// and hid the fact that it was cutting the history window short -- the
	// silent edge-hold fixed 2026-08-30 (core/hzceiling_test.go). With the
	// count now a memory bound only, 5ms spacing keeps a full 600ms instead.
	if want := 1 + defaultSnapshotAgeMs/5; len(b.snapshots) != want {
		t.Fatalf("buffer holds %d snapshots, want %d (a %dms window at 5ms spacing)",
			len(b.snapshots), want, defaultSnapshotAgeMs)
	}
	for i := 1; i < len(b.snapshots); i++ {
		if b.snapshots[i].Timestamp <= b.snapshots[i-1].Timestamp {
			t.Fatalf("buffer is not ordered at %d: %d after %d", i, b.snapshots[i].Timestamp, b.snapshots[i-1].Timestamp)
		}
	}
	if b.newestTimestamp() != 1000+int64(n-1)*5 {
		t.Fatalf("newest = %d, want the last one added", b.newestTimestamp())
	}
}
