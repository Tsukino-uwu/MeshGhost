package relay

import (
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func openEscrows(tc *testClient, n int, counterparty string, prefix string, abort bool) {
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("%s%d", prefix, i)
		tc.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowOpen, ID: id, With: counterparty})
		if abort {
			tc.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowAbort, ID: id})
		}
		// Two messages an iteration at 25ms is 80/s, under the 120/s flood cap with margin for timer granularity.
		time.Sleep(25 * time.Millisecond)
	}
}

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

// TestAbortedEscrowsDoNotCountAgainstTheRoomCap: a terminal exchange is kept for protocol.EscrowRetention but does
// not count against MaxEscrowsPerRoom.
func TestAbortedEscrowsDoNotCountAgainstTheRoomCap(t *testing.T) {
	addr := startServer(t)

	alice := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEscrowV1})
	defer alice.conn.Close()
	wa := alice.expectWelcome(timeout)
	bob := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureEscrowV1})
	defer bob.conn.Close()
	wb := bob.expectWelcome(timeout)

	// More than the per-member live cap is fine: each is aborted before the next is opened.
	openEscrows(alice, protocol.MaxEscrowsPerRoom, wb.PlayerID, "dead", true)

	bob.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowOpen, ID: "fresh", With: wa.PlayerID})
	if st := escrowStateFor(bob, "fresh"); st.Phase != protocol.EscrowPhaseOpen {
		t.Fatalf("bob's open after %d aborted exchanges got phase %q reason %q, want %q",
			protocol.MaxEscrowsPerRoom, st.Phase, st.Reason, protocol.EscrowPhaseOpen)
	}
}

// TestOneMemberCannotHoldTheWholeEscrowTable: live exchanges are capped per opener, never per party, so naming a
// victim as the counterparty cannot lock them out.
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

	bob.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowOpen, ID: "bobs", With: wa.PlayerID})
	if st := escrowStateFor(bob, "bobs"); st.Phase != protocol.EscrowPhaseOpen {
		t.Fatalf("bob's open while alice holds %d exchanges got %q/%q, want open",
			protocol.MaxLiveEscrowsPerMember, st.Phase, st.Reason)
	}
}
