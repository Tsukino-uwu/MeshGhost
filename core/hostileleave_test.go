package core

import (
	"encoding/json"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestARelayCannotLeaveThisCoresOwnGhosts: a relay has nothing to say about ids this core minted. Leave is gated like
// Join and State, or a relay, hostile or merely echoing an id, despawns the player's own chaser pack or replay; a leave
// needs no plausible contents at all.
func TestARelayCannotLeaveThisCoresOwnGhosts(t *testing.T) {
	for _, id := range []string{"chaser:1", "replay:lap1", "chaser:", "replay:"} {
		t.Run(id, func(t *testing.T) {
			c := New()

			// Through the real admission, not by writing the maps: both are made lazily.
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

// TestARelaysLeaveStillWorksForARealPeer: refusing local ids must not refuse anybody else, or every ghost in the room
// stays on screen forever.
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
