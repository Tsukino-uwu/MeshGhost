package core

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestRelaySuppliedIDsAreBoundedAndOutsideTheLocalNamespace: a relay-announced player_id is a map key in four tables
// and reaches the game mod verbatim, so its length is bounded, and a local-peer prefix is refused: "chaser:1" from a
// relay would land in this core's own chaser buffer, render cosmetic and, exempt from the stale age-out, never despawn.
func TestRelaySuppliedIDsAreBoundedAndOutsideTheLocalNamespace(t *testing.T) {
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

	overlong := strings.Repeat("x", protocol.MaxHelloFieldLenForID+1)
	deliver(protocol.TypeWelcome, protocol.Welcome{
		PlayerID: "me",
		Roster:   []string{"p7", overlong, "chaser:1", "replay:someclip"},
	})
	<-welcome

	c.mu.Lock()
	_, ordinary := c.roster["p7"]
	_, admittedOverlong := c.roster[overlong]
	_, admittedChaser := c.roster["chaser:1"]
	_, admittedReplay := c.roster["replay:someclip"]
	c.mu.Unlock()

	if !ordinary {
		t.Fatal("an ordinary relay-assigned id was refused; the gate is too tight")
	}
	if admittedOverlong {
		t.Fatalf("a %d-byte player_id was admitted to the roster; the bound is %d",
			len(overlong), protocol.MaxHelloFieldLenForID)
	}
	if admittedChaser || admittedReplay {
		t.Fatal("the relay named an id inside this core's OWN local-peer namespace and it was " +
			"admitted -- such an id renders cosmetic and is exempt from the stale age-out, so it " +
			"never despawns")
	}

	// The same gate on the join arm, which is the other door into the roster.
	deliver(protocol.TypeJoin, protocol.Join{PlayerID: "chaser:2"})
	deliver(protocol.TypeJoin, protocol.Join{PlayerID: overlong + "j"})
	c.mu.Lock()
	_, joinedChaser := c.roster["chaser:2"]
	_, joinedOverlong := c.roster[overlong+"j"]
	c.mu.Unlock()
	if joinedChaser {
		t.Fatal("a join naming this core's local-peer namespace was admitted")
	}
	if joinedOverlong {
		t.Fatal("a join with an unbounded player_id was admitted")
	}
}
