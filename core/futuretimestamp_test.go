package core

// B4 from the 2026-09-12 adversarial review (P2b-2). The stale age-out judged
// silence by the newest TIMESTAMP in a peer's buffer -- a number the peer
// chooses -- and MaxTimestampMs is 1<<42 ms, which lands in the year 2109. Any
// in-schema future timestamp therefore put a peer permanently past the cutoff:
// never aged out, never despawned, holding one of the 512 roster seats for the
// rest of the session, with nothing logged anywhere.
//
// The peer does not even have to keep sending. One state is enough, and then
// silence forever.
//
// Fixed by ALSO judging arrival, on the receiver's own clock -- see
// remoteBuffer.lastArrivalMs for why it is an extra condition rather than a
// replacement (a live peer satisfies both, so nothing that survives today
// despawns now).

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func TestAPeerCannotOutlastTheAgeOutWithAFutureTimestamp(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk

	now := clk.Now().UnixMilli()

	c.mu.Lock()
	c.admitToRosterLocked("liar")
	c.admitToRosterLocked("honest")
	c.mu.Unlock()

	// Comfortably inside MaxTimestampMs, so ValidateState accepts it: this is a
	// legal state, not a malformed one. That is the whole difficulty of the
	// finding -- there is no bad field to refuse.
	future := now + 365*24*60*60*1000
	if future > protocol.MaxTimestampMs {
		t.Fatalf("test premise broken: %d is past MaxTimestampMs", future)
	}
	c.storeRemoteState(protocol.State{
		PlayerID: "liar", Timestamp: future, AreaID: "town", Position: []float64{1, 2},
	})
	c.storeRemoteState(protocol.State{
		PlayerID: "honest", Timestamp: now, AreaID: "town", Position: []float64{3, 4},
	})

	// Both are live right now, which is the control: the fix must not despawn
	// anything that is actually sending.
	if got, _ := c.remoteStatesAt(clk.Now().UnixMilli()); len(got) != 2 {
		t.Fatalf("expected both peers to render while both are fresh, got %d", len(got))
	}

	// Now nobody sends anything for well past DefaultRemoteStaleAfter.
	clk.Advance(30 * time.Second)
	c.remoteStatesAt(clk.Now().UnixMilli())

	c.mu.Lock()
	_, liarSeated := c.roster["liar"]
	_, honestSeated := c.roster["honest"]
	c.mu.Unlock()

	if honestSeated {
		t.Error("the honest peer kept its seat after 30s of silence -- the age-out did not run at all, " +
			"so this test proves nothing about the liar")
	}
	// Before the fix: still seated, and still seated in the year 2109.
	if liarSeated {
		t.Error("a peer that sent one state dated a year ahead and then went silent forever kept its " +
			"roster seat -- the age-out asked the peer what time it was")
	}
}

// The same trick through the side door B3 opened: prev carries its own
// timestamp, ApplyPrev copies it verbatim, and validPrev applied every bound
// ValidateState applies EXCEPT this one.
func TestAFutureTimestampCannotRideInOnPrev(t *testing.T) {
	st := protocol.State{
		PlayerID: "liar", Timestamp: 1000, AreaID: "town", Position: []float64{1, 2},
		Prev: &protocol.StatePrev{Seq: 1, Timestamp: protocol.MaxTimestampMs + 1},
	}
	// Before the fix: accepted, and the reconstructed prev sample went into the
	// buffer as the newest thing the peer had ever sent.
	if protocol.ValidateState(st) {
		t.Fatal("a state carrying a prev whose timestamp is past MaxTimestampMs was accepted -- " +
			"validPrev promises every bound the carrying state must meet")
	}

	negative := st
	negative.Prev = &protocol.StatePrev{Seq: 1, Timestamp: -1}
	if protocol.ValidateState(negative) {
		t.Fatal("a state carrying a prev with a negative timestamp was accepted")
	}

	ok := st
	ok.Prev = &protocol.StatePrev{Seq: 1, Timestamp: 900}
	if !protocol.ValidateState(ok) {
		t.Fatal("an ordinary prev was refused -- the new bound is rejecting legitimate loss cover")
	}
}
