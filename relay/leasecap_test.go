package relay

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

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

func claim(r *Room, from, key string) {
	r.handleLease(from, protocol.Lease{Op: protocol.LeaseClaim, Key: key})
}

func lastLeaseReason(t *testing.T, rt *recordingTransport) string {
	t.Helper()
	states := rt.leaseStates(t)
	if len(states) == 0 {
		t.Fatal("no lease message at all -- a refusal that says nothing leaves the asker " +
			"waiting for an answer that never comes")
	}
	return string(states[len(states)-1].Reason)
}

func TestOneMemberCannotClaimTheWholeLeaseTable(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "hog", "p2")

	for i := 0; i < maxLeasesPerMember; i++ {
		claim(r, "hog", fmt.Sprintf("k%d", i))
	}
	if got := lastLeaseReason(t, rts["hog"]); got != string(protocol.LeaseGranted) {
		t.Fatalf("claim %d of its own share was answered %q, want it granted",
			maxLeasesPerMember, got)
	}

	claim(r, "hog", "one-too-many")
	if got := lastLeaseReason(t, rts["hog"]); got != string(protocol.LeaseTooMany) {
		t.Fatalf("a claim past the per-member share was answered %q, want %q",
			got, protocol.LeaseTooMany)
	}

	claim(r, "p2", "p2s-key")
	if got := lastLeaseReason(t, rts["p2"]); got != string(protocol.LeaseGranted) {
		t.Fatalf("another member's claim was answered %q while one member sat at its share -- "+
			"that is the starvation the per-member bound exists to prevent", got)
	}
}

// Refusing a renew at the cap would make a member lose its own keys, which is worse than the hoarding the cap prevents.
func TestAMemberAtItsCapCanStillRenewWhatItHolds(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "hog")

	for i := 0; i < maxLeasesPerMember; i++ {
		claim(r, "hog", fmt.Sprintf("k%d", i))
	}

	// A re-claim by the holder counts as a renew.
	claim(r, "hog", "k0")
	if got := lastLeaseReason(t, rts["hog"]); got != string(protocol.LeaseGranted) {
		t.Fatalf("a re-claim of a key this member already holds was answered %q at its cap", got)
	}
	r.handleLease("hog", protocol.Lease{Op: protocol.LeaseRenew, Key: "k0"})
	if got := lastLeaseReason(t, rts["hog"]); got != string(protocol.LeaseGranted) {
		t.Fatalf("an explicit renew at the cap was answered %q", got)
	}

	r.mu.Lock()
	held := r.leasesBy["hog"]
	r.mu.Unlock()
	if held != maxLeasesPerMember {
		t.Fatalf("renewing changed the holder's count to %d, want %d -- a renew takes no new slot",
			held, maxLeasesPerMember)
	}
}

// TestTheRoomLeaseTableHasACapOfItsOwn uses enough members that none reaches its own share first.
func TestTheRoomLeaseTableHasACapOfItsOwn(t *testing.T) {
	members := protocol.MaxLeasesPerRoom/maxLeasesPerMember + 1
	ids := make([]string, 0, members)
	for i := 0; i < members; i++ {
		ids = append(ids, fmt.Sprintf("m%d", i))
	}
	r, rts := worldRoom(t, worldFeatures, ids...)

	filled := 0
	for _, id := range ids {
		for i := 0; i < maxLeasesPerMember && filled < protocol.MaxLeasesPerRoom; i++ {
			claim(r, id, fmt.Sprintf("%s-k%d", id, i))
			filled++
		}
	}
	r.mu.Lock()
	total := len(r.leases)
	r.mu.Unlock()
	if total != protocol.MaxLeasesPerRoom {
		t.Fatalf("filled the table to %d, want %d -- the rest of this test is about what "+
			"happens AT the cap", total, protocol.MaxLeasesPerRoom)
	}

	// The last member is under its own share, so only the room bound can refuse this.
	last := ids[len(ids)-1]
	claim(r, last, "past-the-room-cap")
	if got := lastLeaseReason(t, rts[last]); got != string(protocol.LeaseTooMany) {
		t.Fatalf("a claim against a full room table was answered %q, want %q -- without the "+
			"room bound a client can grow the relay's table forever by claiming a fresh key "+
			"per message", got, protocol.LeaseTooMany)
	}
}
