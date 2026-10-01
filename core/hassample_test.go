package core

// hasSample binary-searches the run sharing the queried timestamp, and the risk is a wrong answer: a false negative
// re-inserts a sample already held, a false positive is the loss cover silently not covering. So it is compared with a
// linear scan over duplicate timestamps, out-of-order arrival, and seq decoupled from timestamp (a lying sender).

import (
	"math/rand"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// linearHasSeq is the scan hasSample replaced, kept as the oracle.
func linearHasSeq(b *remoteBuffer, seq uint64) bool {
	for i := range b.snapshots {
		if b.snapshots[i].Seq == seq {
			return true
		}
	}
	return false
}

func TestHasSampleAgreesWithTheScanItReplaced(t *testing.T) {
	rng := rand.New(rand.NewSource(20260912))

	for trial := 0; trial < 200; trial++ {
		b := &remoteBuffer{historyMs: maxHistoryMs}
		// Timestamps from a small set, so runs of equal timestamps are common.
		type held struct {
			seq uint64
			ts  int64
		}
		var added []held
		for i := 0; i < 40; i++ {
			ts := int64(1000 + rng.Intn(8)*10)
			seq := uint64(rng.Intn(50))
			b.add(protocol.State{PlayerID: "p", Seq: seq, Timestamp: ts, Position: []float64{0, 0}})
			added = append(added, held{seq, ts})
		}

		for _, h := range added {
			// The oracle answers on seq alone, so it is asked only where the pair is consistent, as BuildPrev
			// guarantees for a real prev.
			want := linearHasSeq(b, h.seq)
			got := b.hasSample(h.seq, h.ts)
			if !got && want && sampleHeldAt(b, h.seq, h.ts) {
				t.Fatalf("trial %d: hasSample missed seq %d at ts %d, which is in the buffer -- "+
					"the loss cover would re-insert a sample the ghost has already walked",
					trial, h.seq, h.ts)
			}
			if got && !sampleHeldAt(b, h.seq, h.ts) {
				t.Fatalf("trial %d: hasSample claimed seq %d at ts %d is held when it is not -- "+
					"the loss cover would skip a sample that really was lost, which looks "+
					"exactly like the packet loss it exists to hide",
					trial, h.seq, h.ts)
			}
		}
		for i := 0; i < 20; i++ {
			seq, ts := uint64(1000+i), int64(500+i)
			if b.hasSample(seq, ts) {
				t.Fatalf("trial %d: hasSample claimed an unseen sample (seq %d, ts %d) is held", trial, seq, ts)
			}
		}
	}
}

// sampleHeldAt is the honest question hasSample answers: is this pair present.
func sampleHeldAt(b *remoteBuffer, seq uint64, ts int64) bool {
	for i := range b.snapshots {
		if b.snapshots[i].Seq == seq && b.snapshots[i].Timestamp == ts {
			return true
		}
	}
	return false
}

// TestHasSampleFindsThePrevOfTheNewestSampleOnAFullBuffer: the question every state on a lossy link asks.
func TestHasSampleFindsThePrevOfTheNewestSampleOnAFullBuffer(t *testing.T) {
	b := &remoteBuffer{historyMs: maxHistoryMs}
	for i := 0; i < maxSnapshots; i++ {
		b.add(protocol.State{PlayerID: "p", Seq: uint64(i), Timestamp: int64(i), Position: []float64{0, 0}})
	}
	if len(b.snapshots) != maxSnapshots {
		t.Fatalf("buffer holds %d, want a full %d", len(b.snapshots), maxSnapshots)
	}
	newest := b.snapshots[len(b.snapshots)-1]
	prev := b.snapshots[len(b.snapshots)-2]
	if !b.hasSample(prev.Seq, prev.Timestamp) {
		t.Fatal("the sample immediately before the newest was reported missing on a full buffer")
	}
	if b.hasSample(newest.Seq+1, newest.Timestamp+1) {
		t.Fatal("a sample that has not arrived yet was reported held")
	}
}
