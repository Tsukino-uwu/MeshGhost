package core

import (
	"encoding/json"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// A relay has nothing to say about ids this core minted (X1-5, 2026-09-12).
//
// `Join` above it and `State` below it both refuse an id that fails
// `acceptableRelayPeerID`. `Leave`, sitting between them, took whatever
// arrived -- so a relay that says `leave` for "chaser:1" or "replay:lap1"
// reached straight past every namespace guard this pass added and despawned the
// PLAYER'S OWN ghost: the chaser pack they are racing, or the replay they are
// following, gone mid-run with nothing in any log to say why.
//
// It is the cheapest thing a hostile relay can do, too, because a leave needs no
// plausible contents at all -- a state has to look like a state.
//
// A relay does not have to be malicious for this to bite, only confused: the
// core hands the adapter local ghosts under these prefixes and the relay never
// sees them, so any relay that echoed an id back from somewhere it should not
// have would produce the same despawn.

func TestARelayCannotLeaveThisCoresOwnGhosts(t *testing.T) {
	for _, id := range []string{"chaser:1", "replay:lap1", "chaser:", "replay:"} {
		t.Run(id, func(t *testing.T) {
			c := New()

			// Stood up through the real admission, not by writing the maps:
			// both are made lazily, and a test that reaches around that is
			// testing a state this core cannot actually be in.
			c.mu.Lock()
			c.admitToRosterLocked(id)
			c.mu.Unlock()
			c.storeRemoteName(id, &protocol.Nametag{Name: "mine"})

			payload, err := json.Marshal(protocol.Leave{PlayerID: id})
			if err != nil {
				t.Fatalf("marshal leave: %v", err)
			}
			env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeLeave, Payload: payload})
			if err != nil {
				t.Fatalf("marshal envelope: %v", err)
			}
			c.handleRelayMessage(nil, env, nil, nil)

			c.mu.Lock()
			_, seated := c.roster[id]
			_, named := c.remoteNames[id]
			c.mu.Unlock()

			if !seated {
				t.Fatalf("a relay's leave for %q took this core's own roster seat -- the player's "+
					"own ghost is gone and the relay never knew that id existed", id)
			}
			if !named {
				t.Fatalf("a relay's leave for %q dropped this core's own nametag", id)
			}
		})
	}
}

// TestARelaysLeaveStillWorksForARealPeer is the half that keeps the gate from
// being a regression of its own: refusing local ids must not refuse anybody
// else, or every ghost in the room stays on screen forever.
func TestARelaysLeaveStillWorksForARealPeer(t *testing.T) {
	c := New()
	c.mu.Lock()
	c.admitToRosterLocked("p7")
	c.mu.Unlock()
	c.storeRemoteName("p7", &protocol.Nametag{Name: "theirs"})

	payload, err := json.Marshal(protocol.Leave{PlayerID: "p7"})
	if err != nil {
		t.Fatalf("marshal leave: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeLeave, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	c.handleRelayMessage(nil, env, nil, nil)

	c.mu.Lock()
	_, seated := c.roster["p7"]
	_, named := c.remoteNames["p7"]
	c.mu.Unlock()

	if seated {
		t.Fatal("a real peer's leave left its roster seat behind")
	}
	if named {
		t.Fatal("a real peer's leave left its nametag behind")
	}
}
