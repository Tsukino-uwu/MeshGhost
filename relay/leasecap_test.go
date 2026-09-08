package relay

// The lease table's two bounds. Both were uncovered until 2026-09-08: the
// room-wide one had existed since the plane was written and no test ever
// reached it -- deleting the branch left the relay with an unbounded map keyed
// by peer-chosen strings and the suite green -- and the per-member one did not
// exist at all, which is the abuse escrow had already been fixed for on
// 2026-09-02 (docs/security.md carried the lease half as an accepted risk).

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// leaseStates returns just the lease_state messages this member received,
// decoded, in write order.
func (rt *recordingTransport) leaseStates(t *testing.T) []protocol.LeaseState {
	t.Helper()
	var out []protocol.LeaseState
	for _, env := range rt.received(t) {
		if env.Type != protocol.TypeLeaseState {
			continue
		}
		var st protocol.LeaseState
		if err := json.Unmarshal(env.Payload, &st); err != nil {
			t.Fatalf("unmarshal lease_state: %v", err)
		}
		out = append(out, st)
	}
	return out
}

// lastLeaseState is the answer to the claim just made -- the last lease_state
// this member was sent.
func lastLeaseState(t *testing.T, rt *recordingTransport) protocol.LeaseState {
	t.Helper()
	states := rt.leaseStates(t)
	if len(states) == 0 {
		t.Fatal("no lease_state arrived at all")
	}
	return states[len(states)-1]
}

// claimKeys has holder claim n keys named prefix0..prefixN-1, and fails the
// test if any of them is refused.
func claimKeys(t *testing.T, r *Room, rt *recordingTransport, holder, prefix string, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		key := fmt.Sprintf("%s%d", prefix, i)
		r.handleLease(holder, protocol.Lease{Op: protocol.LeaseClaim, Key: key})
		if st := lastLeaseState(t, rt); st.Reason != protocol.LeaseGranted {
			t.Fatalf("%s's claim on %q (number %d) was answered %q, want %q",
				holder, key, i+1, st.Reason, protocol.LeaseGranted)
		}
	}
}

// TestOneMemberCannotClaimEveryLeaseInTheRoom is F5 of the 2026-09-08 review.
// A re-claim by the current holder is a renew, so a held key never lapses: with
// only the room-wide cap, one member could take all protocol.MaxLeasesPerRoom
// keys, renew them forever, and every other member's claim came back
// LeaseTooMany for as long as it cared to keep going. In a world.v1 room that
// is a write lockout, since a world write is only accepted from the holder of
// the lease it names.
func TestOneMemberCannotClaimEveryLeaseInTheRoom(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1", "p2")

	claimKeys(t, r, rts["p1"], "p1", "hog", maxLeasesPerMember)

	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "onemore"})
	if st := lastLeaseState(t, rts["p1"]); st.Reason != protocol.LeaseTooMany {
		t.Fatalf("p1's claim number %d was answered %q, want %q",
			maxLeasesPerMember+1, st.Reason, protocol.LeaseTooMany)
	}

	// The room's table has 256-32 keys free, and p2 must be able to use it.
	r.handleLease("p2", protocol.Lease{Op: protocol.LeaseClaim, Key: "p2s"})
	if st := lastLeaseState(t, rts["p2"]); st.Reason != protocol.LeaseGranted {
		t.Fatalf("p2's first claim while p1 holds %d keys was answered %q, want %q -- "+
			"one member's hoarding must not be another member's refusal",
			maxLeasesPerMember, st.Reason, protocol.LeaseGranted)
	}

	// A member AT its cap can still renew what it already holds, and re-claim
	// it: refusing either would make a retrying client lose its own keys to its
	// own retries, which is exactly what the renew rule exists to prevent.
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseRenew, Key: "hog0"})
	if st := lastLeaseState(t, rts["p1"]); st.Reason != protocol.LeaseGranted {
		t.Fatalf("a renew at the per-member cap was answered %q, want %q", st.Reason, protocol.LeaseGranted)
	}
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "hog0"})
	if st := lastLeaseState(t, rts["p1"]); st.Reason != protocol.LeaseGranted {
		t.Fatalf("a re-claim of its own key at the per-member cap was answered %q, want %q",
			st.Reason, protocol.LeaseGranted)
	}

	// And releasing one gives the slot back: the count tracks the table rather
	// than counting claims ever made.
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseRelease, Key: "hog0"})
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "afterrelease"})
	if st := lastLeaseState(t, rts["p1"]); st.Reason != protocol.LeaseGranted {
		t.Fatalf("a claim after releasing one at the cap was answered %q, want %q -- "+
			"the per-member count did not come back down", st.Reason, protocol.LeaseGranted)
	}
	r.mu.Lock()
	held, counted := len(r.leases), r.leasesBy["p1"]
	r.mu.Unlock()
	if counted != maxLeasesPerMember {
		t.Fatalf("p1 is counted as holding %d keys, want %d -- a count that drifts either "+
			"locks a member out of a table with room in it or un-bounds the cap entirely",
			counted, maxLeasesPerMember)
	}
	if held != maxLeasesPerMember+1 {
		t.Fatalf("the room holds %d keys, want %d", held, maxLeasesPerMember+1)
	}
}

// TestTheRoomWideLeaseCapRefusesAClaimNobodyCanFit is H7 of the same review:
// protocol.MaxLeasesPerRoom and protocol.LeaseTooMany had zero coverage, while
// their twin protocol.WorldTooMany was asserted in world_test.go. The map is
// keyed by peer-chosen strings, so without this bound a room's memory is set by
// whoever is willing to send the most claims.
//
// It takes eight members to reach the room cap now, which is the per-member
// bound above working: filling the table is the room's decision rather than one
// member's persistence.
func TestTheRoomWideLeaseCapRefusesAClaimNobodyCanFit(t *testing.T) {
	fillers := protocol.MaxLeasesPerRoom / maxLeasesPerMember
	ids := make([]string, 0, fillers+1)
	for i := 0; i < fillers; i++ {
		ids = append(ids, fmt.Sprintf("filler%d", i))
	}
	ids = append(ids, "latecomer")
	r, rts := worldRoom(t, worldFeatures, ids...)

	for i := 0; i < fillers; i++ {
		id := ids[i]
		claimKeys(t, r, rts[id], id, id+"key", maxLeasesPerMember)
	}
	r.mu.Lock()
	held := len(r.leases)
	r.mu.Unlock()
	if held != protocol.MaxLeasesPerRoom {
		t.Fatalf("%d members holding %d keys each left the table at %d, want %d",
			fillers, maxLeasesPerMember, held, protocol.MaxLeasesPerRoom)
	}

	// The latecomer is under its own per-member cap and still refused: this is
	// the room-wide branch and nothing else.
	r.handleLease("latecomer", protocol.Lease{Op: protocol.LeaseClaim, Key: "onemore"})
	st := lastLeaseState(t, rts["latecomer"])
	if st.Reason != protocol.LeaseTooMany {
		t.Fatalf("a claim against a full lease table was answered %q, want %q -- silence or a "+
			"grant would leave a client believing it holds a key the relay never recorded",
			st.Reason, protocol.LeaseTooMany)
	}
	if st.Holder != "" {
		t.Fatalf("a LeaseTooMany named %q as the holder; there is no holder to name", st.Holder)
	}
	r.mu.Lock()
	held = len(r.leases)
	r.mu.Unlock()
	if held != protocol.MaxLeasesPerRoom {
		t.Fatalf("the refused claim still grew the table to %d keys", held)
	}
}
