package main

// Tests for the world-custody checker, continuing controlplane_test.go's rule:
// **a checker with no test of its own passes forever**, including on every run
// where the thing it was watching was broken.
//
// That rule is not theoretical here. This checker's first soak reported five
// violations against a relay that was behaving perfectly, then two more, because
// two of its five invariants were wrong — a lease *renew* re-broadcasts
// "granted" (so arming adoption on any grant was wrong), and the rig's own
// optimistic generation counter was being compared against the relay's
// authoritative one (so a refused write looked like the world going backwards).
// Both are pinned below. A checker that cries wolf gets switched off, which
// costs exactly as much as a checker that never notices.
//
// Every test here uses withCleanViolationCount from controlplane_test.go and the
// same shape: a legal sequence must produce 0, then the one specific defect must
// produce exactly 1. No t.Parallel() — the violation counter is process-wide and
// bracketed, not reset.

import (
	"encoding/json"
	"testing"

	"meshghost/internal/protocol"
)

// testWorldChecker builds a checker for authority "sim" belonging to "self",
// reporting through the package-level counter so withCleanViolationCount sees
// it.
func testWorldChecker() *worldChecker {
	return newWorldChecker(worldConfig{
		on: true, authority: "sim", entities: 2, entityHz: 10,
	}, "self", reportViolation)
}

// genBlob is a discrete-state blob at one generation, the shape entityKey's
// reliable key carries.
func genBlob(t *testing.T, gen uint64) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(worldBlob{Gen: gen, X: 1, Y: 2})
	if err != nil {
		t.Fatalf("marshal blob: %v", err)
	}
	return b
}

// posBlob is a position-only blob, which carries no generation at all — the
// shape posKey's lossy key carries.
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

// TestWorldCheckerCatchesARollback is invariant 4: the whole promise of custody
// is that a successor adopts what the relay holds, so the world never goes
// backwards when the host changes.
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
		// A newer stamp carrying an older generation. Nothing else in the run
		// contradicts it, which is exactly why it has to be caught here.
		w.onWorldState(written(t, 5, "p1", "e0", 2))
	})
	if got != 1 {
		t.Fatalf("a rollback from gen 3 to gen 2 produced %d violations, want 1", got)
	}
}

// TestWorldCheckerCatchesAResurrection is invariant 7: a drop followed by a set
// at or below the dropped generation is a stale write that outlived its own
// deletion — and it is permanent, because the relay's map has the key deleted so
// no snapshot ever contradicts the resurrection.
func TestWorldCheckerCatchesAResurrection(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 2, "p1", "e0", 4))
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "p1", Seq: 3, Reason: protocol.WorldWritten,
			Entries: []protocol.WorldEntry{{Key: "e0", Dropped: true}},
		})
		// A legitimate respawn: a HIGHER generation than the one it died at.
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
		// e1 was never seen, so it died at gen 0 — a set at gen 0 would be
		// nonsense, so use a key with real history instead.
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

// TestWorldCheckerDiscardsAStampOlderThanOneAlreadyApplied is the receiver-side
// ordering rule, and the reason invariant 4 does not fire against the transport.
//
// The relay guarantees a total order, but reliable and lossy delivery to one
// peer are independent, so a lossy write can land ahead of the reliable snapshot
// meant to seed it. Discarding the older stamp is the contract working, not
// failing — so it must produce silence, not a violation.
func TestWorldCheckerDiscardsAStampOlderThanOneAlreadyApplied(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 10, "p1", "e0", 5))
		// Arrives late, stamped earlier, carrying an older generation. Under the
		// seq guard this is dropped in silence; without it, invariant 4 would
		// report a rollback that never happened.
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

// TestWorldCheckerIgnoresGenerationsOnAPositionOnlyKey. A position key rides the
// lossy plane and carries no generation by design, because it has nothing that
// must not go backwards — see entityKey. Invariants 4 and 7 must have nothing to
// say about it, or every lossy write would look like a rollback to gen 0.
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

// TestWorldCheckerDoesNotArmAdoptionOnARenew pins the first of the two bugs this
// checker shipped with.
//
// A lease renew re-broadcasts "granted" with the same holder, and correctly
// produces NO adoption snapshot. Arming invariant 8 on any grant therefore left
// the flag set forever, and the next legitimate write from whoever took over
// later tripped it — five violations in the first soak, against a relay doing
// exactly the right thing.
func TestWorldCheckerDoesNotArmAdoptionOnARenew(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "self"))
		// The adoption that grant owes us.
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 2, Reason: protocol.WorldSnapshot,
		})
		// Renews: same holder, no snapshot owed, and none sent.
		w.onLeaseState(granted(3, "self"))
		w.onLeaseState(granted(4, "self"))
		// Hand off, and watch the new holder write.
		w.onLeaseState(released(5))
		w.onLeaseState(granted(6, "p2"))
		w.onWorldState(written(t, 7, "p2", "e0", 1))
	})
	if got != 0 {
		t.Fatalf("a renew followed by a real handover produced %d violations, want 0 -- a renew "+
			"owes no adoption snapshot, so it must not arm invariant 8", got)
	}
}

// TestWorldCheckerCatchesALiveWriteBeforeItsAdoption is invariant 8, the
// wire-visible form of "the snapshot is built inside the grant".
//
// A live write arriving between the grant and the adoption means the snapshot
// was dispatched after the grant rather than inside it — so this client could
// already have overwritten what it was about to be told to adopt.
func TestWorldCheckerCatchesALiveWriteBeforeItsAdoption(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "self"))
		// Somebody else's write reaches us while we are still waiting for the
		// world we were just granted.
		w.onWorldState(written(t, 2, "self", "e0", 1))
	})
	if got != 1 {
		t.Fatalf("a live write before the adoption snapshot produced %d violations, want 1", got)
	}
}

// TestWorldCheckerCatchesAnEntityLostAcrossAHandover is invariant 6: every key
// this client knew about before it took the lease must be in the world it
// adopts.
func TestWorldCheckerCatchesAnEntityLostAcrossAHandover(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		w.onWorldState(written(t, 2, "p1", "e0", 1))
		w.onWorldState(written(t, 3, "p1", "e1", 1))
		w.onLeaseState(released(4))
		w.onLeaseState(granted(5, "self"))
		// A complete adoption.
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
		// e1 is missing from what we were handed.
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

// TestWorldCheckerAcceptsABatchedAdoption. A full world does not fit one
// datagram, so an adoption arrives as several independently-complete messages
// with no end marker. Invariant 6 must be judged over the whole batch, not per
// message, or every batched adoption would look like a loss.
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

// TestWorldCheckerCatchesAStaleHostsWrite is invariant 5: a written message must
// name whoever held the authority at that message's own stamp.
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
		// Stamped after p2's grant, but claiming p1 wrote it. A later transition
		// closes the window, which is what makes this decidable.
		w.onWorldState(written(t, 6, "p1", "e0", 3))
		w.onLeaseState(released(7))
	})
	if got != 1 {
		t.Fatalf("a stale host's write produced %d violations, want 1", got)
	}
}

// TestWorldCheckerWaitsBeforeJudgingAWriteThatOvertookItsGrant is the reason
// invariant 5 is judged by STAMP rather than by arrival.
//
// On a lossy transport a write can reach a client before the grant that
// authorised it. Reporting that would make the checker complain about the
// transport rather than the relay, so an undecidable case is held until a
// bracketing lease transition arrives — and then judged correctly.
func TestWorldCheckerWaitsBeforeJudgingAWriteThatOvertookItsGrant(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "p1"))
		// p2's write arrives before p2's grant does. Undecidable: nothing yet
		// brackets stamp 5.
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
		// The grant it was waiting for, followed by a transition that closes the
		// window. p2 did hold the authority at stamp 5, so it resolves clean.
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

// TestWorldCheckerDoesNotTreatItsOwnRefusedWriteAsARollback pins the second bug
// this checker shipped with.
//
// A write can be refused — this client lost the authority between deciding to
// write and the relay seeing it — so an optimistic local bump is not evidence
// the world ever reached that generation. Folding what this client SENT into
// what it has RECEIVED left it holding a high-water mark the relay never agreed
// to, and the next snapshot it adopted looked like the world going backwards.
// Every "rollback" the first soak reported was this.
func TestWorldCheckerDoesNotTreatItsOwnRefusedWriteAsARollback(t *testing.T) {
	w := testWorldChecker()

	got := withCleanViolationCount(func() {
		w.onLeaseState(granted(1, "self"))
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 2, Reason: protocol.WorldSnapshot,
			Entries: []protocol.WorldEntry{{Key: "e0", Blob: genBlob(t, 5)}},
		})

		// We issue generations 6 and 7. Both are refused by the relay, so
		// nobody — including us — ever receives them.
		if next := w.nextGen("e0"); next != 6 {
			t.Fatalf("nextGen = %d, want 6", next)
		}
		if next := w.nextGen("e0"); next != 7 {
			t.Fatalf("nextGen = %d, want 7", next)
		}
		w.onWorldState(protocol.WorldState{
			Authority: "sim", Holder: "self", Seq: 3, Reason: protocol.WorldDenied,
		})

		// Later we adopt again, and the relay still says 5 — correctly, since our
		// 6 and 7 never landed. That is not a rollback.
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
	// And the next generation it issues still clears everything it has issued
	// before, so it can never re-use one.
	if next := w.nextGen("e0"); next != 8 {
		t.Fatalf("nextGen = %d after issuing 6 and 7, want 8 -- a re-used generation would be "+
			"invisible to every peer", next)
	}
}

// TestWorldCheckerHoldsWritesUntilItsAdoptionLands is the invariant the relay's
// empty-snapshot behaviour exists to make checkable, and the one whose failure
// is silent: a holder that writes before seeing what it is overwriting rolls the
// world back for everyone.
func TestWorldCheckerHoldsWritesUntilItsAdoptionLands(t *testing.T) {
	w := testWorldChecker()

	w.onLeaseState(granted(1, "self"))
	if w.isHolder() {
		t.Fatal("cleared to write before the adoption snapshot arrived -- a host that writes " +
			"here renumbers from a stale view and rolls the world back for everyone")
	}
	// Even an EMPTY adoption clears it. That is why the relay sends one.
	w.onWorldState(protocol.WorldState{
		Authority: "sim", Holder: "self", Seq: 2, Reason: protocol.WorldSnapshot,
	})
	if !w.isHolder() {
		t.Fatal("still not cleared to write after an empty adoption snapshot -- the rig would " +
			"wait forever and report a clean run having written nothing")
	}
}

// TestWorldCheckerIgnoresAnotherAuthority. Two authorities may share a key, and
// a checker watching one must not judge the other's traffic.
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
