package core

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestRosterIsBoundedAgainstARelayThatAnnouncesWithoutEnd: the roster is the
// one thing between a hostile or broken relay and the adapter, which spawns a
// ghost per announced id and counts nothing. Until 2026-09-02 a relay could
// announce ids forever, over welcome or join, and every one became a ghost.
// Found by the 2026-09-02 adversarial review of the peer-to-adapter path.
func TestRosterIsBoundedAgainstARelayThatAnnouncesWithoutEnd(t *testing.T) {
	c := New()
	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)
	deliver := func(kind protocol.MessageType, payload any) {
		t.Helper()
		p, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("marshal payload: %v", err)
		}
		env, err := json.Marshal(protocol.Envelope{Type: kind, Payload: p})
		if err != nil {
			t.Fatalf("marshal envelope: %v", err)
		}
		c.handleRelayMessage(nil, env, welcome, reject)
	}

	// A welcome whose roster is already twice the bound.
	huge := make([]string, 2*protocol.MaxRosterSize)
	for i := range huge {
		huge[i] = fmt.Sprintf("w%d", i)
	}
	deliver(protocol.TypeWelcome, protocol.Welcome{PlayerID: "me", Roster: huge})
	<-welcome

	c.mu.Lock()
	n := len(c.roster)
	c.mu.Unlock()
	if n > protocol.MaxRosterSize {
		t.Fatalf("roster after an oversized welcome holds %d ids, cap is %d", n, protocol.MaxRosterSize)
	}

	// And joins past the bound on top.
	for i := 0; i < protocol.MaxRosterSize; i++ {
		deliver(protocol.TypeJoin, protocol.Join{PlayerID: fmt.Sprintf("j%d", i)})
	}
	c.mu.Lock()
	n = len(c.roster)
	_, lastJoinAdmitted := c.roster[fmt.Sprintf("j%d", protocol.MaxRosterSize-1)]
	c.mu.Unlock()
	if n > protocol.MaxRosterSize {
		t.Fatalf("roster after a join flood holds %d ids, cap is %d", n, protocol.MaxRosterSize)
	}
	if lastJoinAdmitted {
		t.Fatal("a join past the roster cap was admitted")
	}

	// A player who leaves frees a seat for the next join.
	deliver(protocol.TypeLeave, protocol.Leave{PlayerID: "w0"})
	deliver(protocol.TypeJoin, protocol.Join{PlayerID: "after-leave"})
	c.mu.Lock()
	_, admitted := c.roster["after-leave"]
	c.mu.Unlock()
	if !admitted {
		t.Fatal("a join after a leave freed a seat was not admitted")
	}
}
