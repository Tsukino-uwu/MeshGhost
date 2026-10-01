package core

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestAPeerCannotOutlastTheAgeOutWithAFutureTimestamp: a peer chooses its own timestamps, so the age-out also judges
// arrival on this side's clock; one future-dated state and then silence must not hold a seat.
func TestAPeerCannotOutlastTheAgeOutWithAFutureTimestamp(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk

	now := clk.Now().UnixMilli()

	c.mu.Lock()
	c.admitToRosterLocked("liar")
	c.admitToRosterLocked("honest")
	c.mu.Unlock()

	// Inside MaxTimestampMs, so a legal state: there is no bad field to refuse.
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

	// The control: both are live, and nothing that is sending may despawn.
	if got, _ := c.remoteStatesAt(clk.Now().UnixMilli()); len(got) != 2 {
		t.Fatalf("expected both peers to render while both are fresh, got %d", len(got))
	}

	// Well past DefaultRemoteStaleAfter with nobody sending.
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
	if liarSeated {
		t.Error("a peer that sent one state dated a year ahead and then went silent forever kept its " +
			"roster seat -- the age-out asked the peer what time it was")
	}
}

// TestAFutureTimestampCannotRideInOnPrev: prev carries its own timestamp and ApplyPrev copies it verbatim, so
// validPrev bounds it as ValidateState does.
func TestAFutureTimestampCannotRideInOnPrev(t *testing.T) {
	st := protocol.State{
		PlayerID: "liar", Timestamp: 1000, AreaID: "town", Position: []float64{1, 2},
		Prev: &protocol.StatePrev{Seq: 1, Timestamp: protocol.MaxTimestampMs + 1},
	}
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
