package main

// Tests for the invariant checkers themselves.
//
// **A checker with no test of its own passes forever**, including for every
// run where the thing it was watching was broken — which is the worst possible
// failure for a tool whose entire job is to notice. These feed each checker
// the violation it exists to catch and require it to say so, and they exist
// because a soak run reporting "no invariant violations" is otherwise
// indistinguishable from a soak run that checked nothing.

import (
	"encoding/json"
	"testing"

	"meshghost/internal/protocol"
)

// withCleanViolationCount runs fn with the process-wide counter reset, and
// returns how many violations fn produced. The counter is package-level
// because the exit code is, so a test has to isolate itself.
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

	// The three planes share one room counter, so the check must span them —
	// a lease_state arriving behind an event is the same defect.
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
		// A denial names the current holder but is not a state change, so it
		// must not be mistaken for a second grant.
		cp.onLeaseState(protocol.LeaseState{Seq: 2, Key: "k", Holder: "p1", Reason: protocol.LeaseDenied})
		cp.onLeaseState(protocol.LeaseState{Seq: 3, Key: "k", Reason: protocol.LeaseReleased})
		cp.onLeaseState(protocol.LeaseState{Seq: 4, Key: "k", Holder: "p2", Reason: protocol.LeaseGranted})
	})
	if got != 0 {
		t.Fatalf("a legal grant/deny/release/grant sequence reported %d violation(s), want 0", got)
	}

	got = withCleanViolationCount(func() {
		// p3 granted while p2 still holds it, with no release in between.
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
		// Committed with only one side's contribution: one party completed a
		// swap the other never contributed to.
		cp.onEscrowState(protocol.EscrowState{Seq: 2, ID: "t2", Phase: protocol.EscrowPhaseCommitted,
			Blobs: map[string]json.RawMessage{"p1": json.RawMessage(`1`)}})
	})
	if got != 1 {
		t.Fatalf("a half-committed exchange reported %d violation(s), want 1", got)
	}

	got = withCleanViolationCount(func() {
		// An abort must destroy both deposits, never deliver them.
		cp.onEscrowState(protocol.EscrowState{Seq: 3, ID: "t3", Phase: protocol.EscrowPhaseAborted, Blobs: blobs})
	})
	if got != 1 {
		t.Fatalf("an abort that still delivered blobs reported %d violation(s), want 1", got)
	}
}
