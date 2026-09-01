package relay

import (
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// Both tests below come from the 2026-09-02 adversarial review, where two
// independent reviewers confirmed the same thing by experiment: one member of
// an escrow.v1 room could refuse every other member's trades for as long as it
// liked, staying under the flood cap the whole time. See docs/security.md.

// openEscrows has tc open n exchanges with counterparty, paced under the
// per-second flood cap, and abort each one if abort is set.
func openEscrows(tc *testClient, n int, counterparty string, prefix string, abort bool) {
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("%s%d", prefix, i)
		tc.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowOpen, ID: id, With: counterparty})
		if abort {
			tc.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowAbort, ID: id})
		}
		// Two messages per iteration when aborting, so 25ms keeps this at
		// 80/s, under the 120/s flood cap with margin for timer granularity.
		time.Sleep(25 * time.Millisecond)
	}
}

// escrowStateFor drains escrow_state messages until the one for id arrives.
func escrowStateFor(tc *testClient, id string) protocol.EscrowState {
	tc.t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		st := tc.expectEscrowState(timeout)
		if st.ID == id {
			return st
		}
	}
	tc.t.Fatalf("no escrow_state for %q arrived", id)
	return protocol.EscrowState{}
}

// TestAbortedEscrowsDoNotCountAgainstTheRoomCap: a terminal exchange is kept
// for protocol.EscrowRetention so a party that dropped mid-trade can learn how
// it ended -- but until 2026-09-02 those retained records counted against
// MaxEscrowsPerRoom, so one member opening and aborting 64 exchanges made
// every open in the room, by anyone, come back aborted/rejected for the next
// 60 seconds, renewable forever at ~2 messages a second.
func TestAbortedEscrowsDoNotCountAgainstTheRoomCap(t *testing.T) {
	addr := startServer(t)

	alice := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEscrowV1})
	defer alice.conn.Close()
	wa := alice.expectWelcome(timeout)
	bob := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureEscrowV1})
	defer bob.conn.Close()
	wb := bob.expectWelcome(timeout)

	// Fill the room with dead exchanges. More than the per-member live cap
	// is fine here because each is aborted before the next is opened.
	openEscrows(alice, protocol.MaxEscrowsPerRoom, wb.PlayerID, "dead", true)

	bob.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowOpen, ID: "fresh", With: wa.PlayerID})
	if st := escrowStateFor(bob, "fresh"); st.Phase != protocol.EscrowPhaseOpen {
		t.Fatalf("bob's open after %d aborted exchanges got phase %q reason %q, want %q",
			protocol.MaxEscrowsPerRoom, st.Phase, st.Reason, protocol.EscrowPhaseOpen)
	}
}

// TestOneMemberCannotHoldTheWholeEscrowTable: live exchanges are capped per
// opener as well as per room, so filling the room's table takes the room's
// cooperation rather than one member's persistence. Counted by OPENER, not by
// party: counting both sides would let an attacker lock a victim out by
// naming them as the counterparty.
func TestOneMemberCannotHoldTheWholeEscrowTable(t *testing.T) {
	addr := startServer(t)

	alice := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEscrowV1})
	defer alice.conn.Close()
	wa := alice.expectWelcome(timeout)
	bob := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureEscrowV1})
	defer bob.conn.Close()
	wb := bob.expectWelcome(timeout)

	openEscrows(alice, protocol.MaxLiveEscrowsPerMember, wb.PlayerID, "held", false)
	alice.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowOpen, ID: "onemore", With: wb.PlayerID})
	if st := escrowStateFor(alice, "onemore"); st.Phase != protocol.EscrowPhaseAborted || st.Reason != protocol.EscrowReasonRejected {
		t.Fatalf("alice's %dth live open got %q/%q, want aborted/rejected",
			protocol.MaxLiveEscrowsPerMember+1, st.Phase, st.Reason)
	}

	// Bob, named as counterparty on every one of alice's, is not locked out.
	bob.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowOpen, ID: "bobs", With: wa.PlayerID})
	if st := escrowStateFor(bob, "bobs"); st.Phase != protocol.EscrowPhaseOpen {
		t.Fatalf("bob's open while alice holds %d exchanges got %q/%q, want open",
			protocol.MaxLiveEscrowsPerMember, st.Phase, st.Reason)
	}
}
