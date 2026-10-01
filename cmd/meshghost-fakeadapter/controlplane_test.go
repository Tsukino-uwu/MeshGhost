package main

import (
	"encoding/json"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// withCleanViolationCount returns how many violations fn produced, as a difference, since the counter is
// process-wide.
func withCleanViolationCount(fn func()) uint64 {
	before := violations.Load()
	fn()
	return violations.Load() - before
}

func TestOrderingCheckerCatchesAStampArrivingLate(t *testing.T) {
	cp := newControlPlane(0)

	got := withCleanViolationCount(func() {
		cp.onEvent(protocol.Event{Seq: 1, From: "p2"})
		cp.onEvent(protocol.Event{Seq: 2, From: "p2"})
		cp.onEvent(protocol.Event{Seq: 5, From: "p2"}) // gaps are fine: this client only sees a subset
	})
	if got != 0 {
		t.Fatalf("increasing stamps reported %d violation(s), want 0 — gaps are legal", got)
	}

	got = withCleanViolationCount(func() {
		cp.onEvent(protocol.Event{Seq: 3, From: "p2"}) // already saw 5
	})
	if got != 1 {
		t.Fatalf("an out-of-order stamp reported %d violation(s), want 1", got)
	}

	// The planes share one room counter, so a lease_state arriving behind an event is the same defect.
	got = withCleanViolationCount(func() {
		cp.onLeaseState(protocol.LeaseState{Seq: 2, Key: "k", Reason: protocol.LeaseGranted})
	})
	if got != 1 {
		t.Fatalf("an out-of-order lease_state reported %d violation(s), want 1 — the planes share one counter", got)
	}
}

func TestExclusivityCheckerCatchesTwoHoldersOfOneKey(t *testing.T) {
	cp := newControlPlane(0)

	got := withCleanViolationCount(func() {
		cp.onLeaseState(protocol.LeaseState{Seq: 1, Key: "k", Holder: "p1", Reason: protocol.LeaseGranted})
		// A denial names the current holder but is not a state change, so it is not a second grant.
		cp.onLeaseState(protocol.LeaseState{Seq: 2, Key: "k", Holder: "p1", Reason: protocol.LeaseDenied})
		cp.onLeaseState(protocol.LeaseState{Seq: 3, Key: "k", Reason: protocol.LeaseReleased})
		cp.onLeaseState(protocol.LeaseState{Seq: 4, Key: "k", Holder: "p2", Reason: protocol.LeaseGranted})
	})
	if got != 0 {
		t.Fatalf("a legal grant/deny/release/grant sequence reported %d violation(s), want 0", got)
	}

	got = withCleanViolationCount(func() {
		cp.onLeaseState(protocol.LeaseState{Seq: 5, Key: "k", Holder: "p3", Reason: protocol.LeaseGranted})
	})
	if got != 1 {
		t.Fatalf("two holders of one key reported %d violation(s), want 1", got)
	}
}

func TestEscrowCheckerCatchesABrokenTerminalState(t *testing.T) {
	cp := newControlPlane(0)
	blobs := map[string]json.RawMessage{"p1": json.RawMessage(`1`), "p2": json.RawMessage(`2`)}

	got := withCleanViolationCount(func() {
		cp.onEscrowState(protocol.EscrowState{Seq: 1, ID: "t1", Phase: protocol.EscrowPhaseCommitted, Blobs: blobs})
	})
	if got != 0 {
		t.Fatalf("a committed exchange carrying both blobs reported %d violation(s), want 0", got)
	}

	got = withCleanViolationCount(func() {
		cp.onEscrowState(protocol.EscrowState{Seq: 2, ID: "t2", Phase: protocol.EscrowPhaseCommitted,
			Blobs: map[string]json.RawMessage{"p1": json.RawMessage(`1`)}})
	})
	if got != 1 {
		t.Fatalf("a half-committed exchange reported %d violation(s), want 1", got)
	}

	got = withCleanViolationCount(func() {
		cp.onEscrowState(protocol.EscrowState{Seq: 3, ID: "t3", Phase: protocol.EscrowPhaseAborted, Blobs: blobs})
	})
	if got != 1 {
		t.Fatalf("an abort that still delivered blobs reported %d violation(s), want 1", got)
	}
}
