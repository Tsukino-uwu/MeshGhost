package relay

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// THE LEASE TABLE'S TWO BOUNDS HAD NO COVERAGE AT ALL (review H7), while the
// world plane's identical one -- WorldTooMany -- was asserted. Both bounds are
// resource limits on a map a peer can grow by asking, and the per-member half
// was added 2026-09-08 to close an abuse docs/security.md had been carrying as
// an accepted risk: a re-claim by the holder is a RENEW, so a member that
// claimed every key and kept renewing answered every other member's claim with
// LeaseTooMany indefinitely -- and in a world.v1 room that stops anyone else
// writing to the world at all, since a write is only taken from the lease
// holder.
//
// The refusal must be ANSWERED rather than dropped, for the reason the world
// plane's says: silence leaves the asker waiting for a reply that never comes.

// leaseStates returns just this member's lease messages, decoded, in order.
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

// lastLeaseReason is the reason on this member's most recent lease message.
func lastLeaseReason(t *testing.T, rt *recordingTransport) string {
	t.Helper()
	states := rt.leaseStates(t)
	if len(states) == 0 {
		t.Fatal("no lease message at all -- a refusal that says nothing leaves the asker " +
			"waiting for an answer that never comes")
	}
	return string(states[len(states)-1].Reason)
}

// ONE MEMBER MAY NOT TAKE THE WHOLE TABLE. The per-member share is
// MaxLeasesPerRoom/8, the same ratio escrow uses, so eight cooperating members
// are needed to fill it -- one acting alone is refused at its own share.
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

	// AND THE ROOM STILL WORKS FOR EVERYONE ELSE, which is the whole point of
	// the per-member bound: before it, the room cap was reachable by one
	// member and every other member's claim was refused for as long as that
	// member kept renewing.
	claim(r, "p2", "p2s-key")
	if got := lastLeaseReason(t, rts["p2"]); got != string(protocol.LeaseGranted) {
		t.Fatalf("another member's claim was answered %q while one member sat at its share -- "+
			"that is the starvation the per-member bound exists to prevent", got)
	}
}

// A RENEW IS NOT A NEW SLOT. A member at its own cap must be able to keep the
// keys it already holds; refusing its renews would make it lose them to its own
// retries, which is worse than the hoarding the cap prevents.
func TestAMemberAtItsCapCanStillRenewWhatItHolds(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "hog")

	for i := 0; i < maxLeasesPerMember; i++ {
		claim(r, "hog", fmt.Sprintf("k%d", i))
	}

	// A re-claim by the holder, which the code treats as a renew...
	claim(r, "hog", "k0")
	if got := lastLeaseReason(t, rts["hog"]); got != string(protocol.LeaseGranted) {
		t.Fatalf("a re-claim of a key this member already holds was answered %q at its cap", got)
	}
	// ...and an explicit renew.
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

// THE ROOM CAP IS THE OTHER HALF, and it needs enough members that no single
// one hits its own share first -- which is exactly the ratio the per-member
// bound was derived from.
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

	// The last member is nowhere near its own share, so this can only be
	// refused by the room bound.
	last := ids[len(ids)-1]
	claim(r, last, "past-the-room-cap")
	if got := lastLeaseReason(t, rts[last]); got != string(protocol.LeaseTooMany) {
		t.Fatalf("a claim against a full room table was answered %q, want %q -- without the "+
			"room bound a client can grow the relay's table forever by claiming a fresh key "+
			"per message", got, protocol.LeaseTooMany)
	}
}
