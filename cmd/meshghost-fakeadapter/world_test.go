package main

// A legal sequence must produce no violation, then the one defect exactly one. No t.Parallel(): the violation counter
// is process-wide.

import (
	"encoding/json"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// testWorldChecker builds a checker for authority "sim" belonging to "self" that reports through the process-wide
// counter.
func testWorldChecker() *worldChecker {
	return newWorldChecker(worldConfig{
		on: true, authority: "sim", entities: 2, entityHz: 10,
	}, "self", reportViolation)
}

// genBlob is a discrete-state blob at one generation, the shape entityKey's reliable key carries.
func genBlob(t *testing.T, gen uint64) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(worldBlob{Gen: gen, X: 1, Y: 2})
	if err != nil {
		t.Fatalf("marshal blob: %v", err)
	}
	return b
}

// posBlob is a position-only blob with no generation, the shape posKey's lossy key carries.
func posBlob(t *testing.T) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(worldBlob{X: 3, Y: 4})
	if err != nil {
		t.Fatalf("marshal blob: %v", err)
	}
	return b
}

// written is one live write from holder, at seq, setting key to gen.
func written(t *testing.T, seq uint64, holder, key string, gen uint64) protocol.WorldState {
	t.Helper()
	return protocol.WorldState{
		Authority: "sim", Holder: holder, Seq: seq, Reason: protocol.WorldWritten,
		Entries: []protocol.WorldEntry{{Key: key, Blob: genBlob(t, gen)}},
	}
}

func granted(seq uint64, holder string) protocol.LeaseState {
	return protocol.LeaseState{Key: "sim", Holder: holder, Seq: seq, Reason: protocol.LeaseGranted}
}

func released(seq uint64) protocol.LeaseState {
	return protocol.LeaseState{Key: "sim", Seq: seq, Reason: protocol.LeaseReleased}
}

// TestWorldCheckerCatchesARollback is invariant 4.
func TestWorldCheckerCatchesARollback(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 2, "p1", "e0", 1))
		w.onWorldState(written(t, 3, "p1", "e0", 2))
		w.onWorldState(written(t, 4, "p1", "e0", 3))
	})
	if got != 0 {
		t.Fatalf("a monotonically rising world produced %d violations, want 0", got)
	}

	got = withCleanViolationCount(func() {
		// A newer stamp carrying an older generation.
		w.onWorldState(written(t, 5, "p1", "e0", 2))
	})
	if got != 1 {
		t.Fatalf("a rollback from gen 3 to gen 2 produced %d violations, want 1", got)
	}
}

// TestWorldCheckerCatchesAResurrection is invariant 7. A resurrection is permanent: the relay has the key deleted, so
// no snapshot ever contradicts it.
func TestWorldCheckerCatchesAResurrection(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 2, "p1", "e0", 4))
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "p1", Seq: 3, Reason: protocol.WorldWritten,
			Entries: []protocol.WorldEntry{{Key: "e0", Dropped: true}},
		})
		// A legitimate respawn: a higher generation than the one it died at.
		w.onWorldState(written(t, 4, "p1", "e0", 5))
	})
	if got != 0 {
		t.Fatalf("a drop and a legitimate respawn produced %d violations, want 0", got)
	}

	got = withCleanViolationCount(func() {
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "p1", Seq: 5, Reason: protocol.WorldWritten,
			Entries: []protocol.WorldEntry{{Key: "e1", Dropped: true}},
		})
		// e1 was never seen, so it died at gen 0; the real test uses e0, which has history.
		w.onWorldState(written(t, 6, "p1", "e0", 6))
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "p1", Seq: 7, Reason: protocol.WorldWritten,
			Entries: []protocol.WorldEntry{{Key: "e0", Dropped: true}},
		})
		w.onWorldState(written(t, 8, "p1", "e0", 6)) // at the dropped gen: stale
	})
	if got != 1 {
		t.Fatalf("a resurrection at the dropped generation produced %d violations, want 1", got)
	}
}

// TestWorldCheckerDiscardsAStampOlderThanOneAlreadyApplied is the receiver-side ordering rule: reliable and lossy
// delivery to one peer are independent, so discarding an older stamp is the contract working, not a violation.
func TestWorldCheckerDiscardsAStampOlderThanOneAlreadyApplied(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 10, "p1", "e0", 5))
		// Arrives late, stamped earlier, carrying an older generation.
		w.onWorldState(written(t, 9, "p1", "e0", 4))
	})
	if got != 0 {
		t.Fatalf("a late-arriving older stamp produced %d violations, want 0 -- the seq guard "+
			"is what stops the checker reporting the transport instead of the relay", got)
	}
	if w.gen["e0"] != 5 {
		t.Fatalf("the older stamp was applied anyway: gen = %d, want 5", w.gen["e0"])
	}
}

// TestWorldCheckerIgnoresGenerationsOnAPositionOnlyKey: a position key carries no generation, so invariants 4 and 7
// must skip it or every lossy write would look like a rollback to gen 0.
func TestWorldCheckerIgnoresGenerationsOnAPositionOnlyKey(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 2, "p1", "e0", 7))
		for seq := uint64(3); seq < 8; seq++ {
			w.onWorldState(protocol.WorldState{
				Authority: "sim", Holder: "p1", Seq: seq, Reason: protocol.WorldWritten,
				Entries: []protocol.WorldEntry{{Key: "e0.pos", Blob: posBlob(t)}},
			})
		}
	})
	if got != 0 {
		t.Fatalf("position-only writes produced %d violations, want 0", got)
	}
}

// TestWorldCheckerDoesNotArmAdoptionOnARenew: a renew re-broadcasts granted with the same holder and no snapshot, so
// arming invariant 8 on it would trip on the next holder's legitimate write.
func TestWorldCheckerDoesNotArmAdoptionOnARenew(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "self"))
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 2, Reason: protocol.WorldSnapshot,
		})
		// Renews: same holder, no snapshot owed, and none sent.
		w.onLeaseState(granted(3, "self"))
		w.onLeaseState(granted(4, "self"))
		w.onLeaseState(released(5))
		w.onLeaseState(granted(6, "p2"))
		w.onWorldState(written(t, 7, "p2", "e0", 1))
	})
	if got != 0 {
		t.Fatalf("a renew followed by a real handover produced %d violations, want 0 -- a renew "+
			"owes no adoption snapshot, so it must not arm invariant 8", got)
	}
}

// TestWorldCheckerCatchesALiveWriteBeforeItsAdoption is invariant 8: a live write between the grant and the adoption
// means the snapshot was sent after the grant rather than inside it.
func TestWorldCheckerCatchesALiveWriteBeforeItsAdoption(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "self"))
		w.onWorldState(written(t, 2, "self", "e0", 1))
	})
	if got != 1 {
		t.Fatalf("a live write before the adoption snapshot produced %d violations, want 1", got)
	}
}

// TestWorldCheckerCatchesAnEntityLostAcrossAHandover is invariant 6.
func TestWorldCheckerCatchesAnEntityLostAcrossAHandover(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 2, "p1", "e0", 1))
		w.onWorldState(written(t, 3, "p1", "e1", 1))
		w.onLeaseState(released(4))
		w.onLeaseState(granted(5, "self"))
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 6, Reason: protocol.WorldSnapshot,
			Entries: []protocol.WorldEntry{
				{Key: "e0", Blob: genBlob(t, 1)},
				{Key: "e1", Blob: genBlob(t, 1)},
			},
		})
		w.closeAdoption()
	})
	if got != 0 {
		t.Fatalf("a complete adoption produced %d violations, want 0", got)
	}

	w2 := testWorldChecker()
	got = withCleanViolationCount(func() {
		w2.onLeaseState(granted(1, "p1"))
		w2.onWorldState(written(t, 2, "p1", "e0", 1))
		w2.onWorldState(written(t, 3, "p1", "e1", 1))
		w2.onLeaseState(released(4))
		w2.onLeaseState(granted(5, "self"))
		// e1 is missing from the adoption.
		w2.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 6, Reason: protocol.WorldSnapshot,
			Entries: []protocol.WorldEntry{{Key: "e0", Blob: genBlob(t, 1)}},
		})
		w2.closeAdoption()
	})
	if got != 1 {
		t.Fatalf("an adoption missing a known entity produced %d violations, want 1", got)
	}
}

// TestWorldCheckerAcceptsABatchedAdoption: a full world does not fit one datagram, so an adoption arrives as several
// messages with no end marker, and invariant 6 is judged over the whole batch.
func TestWorldCheckerAcceptsABatchedAdoption(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 2, "p1", "e0", 1))
		w.onWorldState(written(t, 3, "p1", "e1", 1))
		w.onLeaseState(released(4))
		w.onLeaseState(granted(5, "self"))
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 6, Reason: protocol.WorldSnapshot,
			Entries: []protocol.WorldEntry{{Key: "e0", Blob: genBlob(t, 1)}},
		})
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 7, Reason: protocol.WorldSnapshot,
			Entries: []protocol.WorldEntry{{Key: "e1", Blob: genBlob(t, 1)}},
		})
		w.closeAdoption()
	})
	if got != 0 {
		t.Fatalf("an adoption split across two messages produced %d violations, want 0", got)
	}
}

// TestWorldCheckerCatchesAStaleHostsWrite is invariant 5.
func TestWorldCheckerCatchesAStaleHostsWrite(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 2, "p1", "e0", 1))
		w.onLeaseState(released(3))
		w.onLeaseState(granted(4, "p2"))
		w.onWorldState(written(t, 5, "p2", "e0", 2))
	})
	if got != 0 {
		t.Fatalf("a clean handover produced %d violations, want 0", got)
	}

	got = withCleanViolationCount(func() {
		// Stamped after p2's grant but claiming p1; the later transition makes it decidable.
		w.onWorldState(written(t, 6, "p1", "e0", 3))
		w.onLeaseState(released(7))
	})
	if got != 1 {
		t.Fatalf("a stale host's write produced %d violations, want 1", got)
	}
}

// TestWorldCheckerWaitsBeforeJudgingAWriteThatOvertookItsGrant: on a lossy transport a write can arrive before its
// grant, so invariant 5 holds it until a bracketing lease transition and judges it then.
func TestWorldCheckerWaitsBeforeJudgingAWriteThatOvertookItsGrant(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		// p2's write arrives before p2's grant: nothing yet brackets stamp 5.
		w.onWorldState(written(t, 5, "p2", "e0", 1))
	})
	if got != 0 {
		t.Fatalf("a write that overtook its own grant produced %d violations while still "+
			"undecidable, want 0", got)
	}
	if len(w.pending) != 1 {
		t.Fatalf("the undecidable write was not held: pending = %d, want 1", len(w.pending))
	}

	got = withCleanViolationCount(func() {
		// The grant, then a transition that closes the window: p2 held the authority at stamp 5.
		w.onLeaseState(granted(4, "p2"))
		w.onLeaseState(released(6))
	})
	if got != 0 {
		t.Fatalf("the held write resolved to %d violations once its grant arrived, want 0", got)
	}
	if len(w.pending) != 0 {
		t.Fatalf("the held write was never resolved: pending = %d, want 0", len(w.pending))
	}
}

// TestWorldCheckerDoesNotTreatItsOwnRefusedWriteAsARollback: a refused write is no evidence the world reached its
// generation, so adopting the relay's older one is not a rollback.
func TestWorldCheckerDoesNotTreatItsOwnRefusedWriteAsARollback(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "self"))
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 2, Reason: protocol.WorldSnapshot,
			Entries: []protocol.WorldEntry{{Key: "e0", Blob: genBlob(t, 5)}},
		})

		// Generations 6 and 7 are issued and refused, so nobody receives them.
		if next := w.nextGen("e0"); next != 6 {
			t.Fatalf("nextGen = %d, want 6", next)
		}
		if next := w.nextGen("e0"); next != 7 {
			t.Fatalf("nextGen = %d, want 7", next)
		}
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 3, Reason: protocol.WorldDenied,
		})

		// Adopting again, the relay still says 5, correctly.
		w.onLeaseState(released(4))
		w.onLeaseState(granted(5, "self"))
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 6, Reason: protocol.WorldSnapshot,
			Entries: []protocol.WorldEntry{{Key: "e0", Blob: genBlob(t, 5)}},
		})
		w.closeAdoption()
	})
	if got != 0 {
		t.Fatalf("adopting a world the relay never advanced produced %d violations, want 0 -- "+
			"what this client SENT is not evidence of what the world reached", got)
	}
	// The next generation still clears everything issued before, so none is re-used.
	if next := w.nextGen("e0"); next != 8 {
		t.Fatalf("nextGen = %d after issuing 6 and 7, want 8 -- a re-used generation would be "+
			"invisible to every peer", next)
	}
}

// TestWorldCheckerHoldsWritesUntilItsAdoptionLands: a holder that writes before seeing what it overwrites rolls the
// world back for everyone, silently.
func TestWorldCheckerHoldsWritesUntilItsAdoptionLands(t *testing.T) {
	w := testWorldChecker()

	w.onLeaseState(granted(1, "self"))
	if w.isHolder() {
		t.Fatal("cleared to write before the adoption snapshot arrived -- a host that writes " +
			"here renumbers from a stale view and rolls the world back for everyone")
	}
	// Even an empty adoption clears it, which is why the relay sends one.
	w.onWorldState(protocol.WorldState{
		Authority: "sim", Holder: "self", Seq: 2, Reason: protocol.WorldSnapshot,
	})
	if !w.isHolder() {
		t.Fatal("still not cleared to write after an empty adoption snapshot -- the rig would " +
			"wait forever and report a clean run having written nothing")
	}
}

// TestWorldCheckerIgnoresAnotherAuthority: two authorities may share a key, and a checker judges only its own.
func TestWorldCheckerIgnoresAnotherAuthority(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 2, "p1", "e0", 5))
		// A blatant rollback, under a different authority.
		other := written(t, 3, "p9", "e0", 1)
		other.Authority = "other-sim"
		w.onWorldState(other)
		// And a lease for a key this checker does not watch.
		w.onLeaseState(protocol.LeaseState{Key: "contended-key", Holder: "p9", Seq: 4,
			Reason: protocol.LeaseGranted})
	})
	if got != 0 {
		t.Fatalf("another authority's traffic produced %d violations, want 0", got)
	}
}
