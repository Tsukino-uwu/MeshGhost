package core

// A peer that stops sending must stop being drawn: a restarted core rejoins as a new player id and the old one never
// sends a Leave, so without aging out its last sample stands there forever.

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// renderOnce drives one render tick, the way an adapter frame does, and reports which ids were drawn and despawned.
func renderOnce(c *Core, rendered map[string]bool) (drawn []string, despawned []string) {
	c.tickRenders(rendered,
		func(id string, st protocol.State, _ orientBracket) { drawn = append(drawn, id) },
		func(id string) { despawned = append(despawned, id) },
	)
	return drawn, despawned
}

func TestASilentPeerIsDespawnedRatherThanLeftStanding(t *testing.T) {
	c := New()
	c.InterpolationDelay = 0
	c.RemoteStaleAfter = 100 * time.Millisecond
	c.playerID = "me"
	c.roster = map[string]int64{"ghosty": 0}

	c.storeRemoteState(protocol.State{
		PlayerID: "ghosty", AreaID: "a", Position: []float64{1, 2}, Timestamp: c.nowMs(),
	})

	rendered := map[string]bool{}
	drawn, _ := renderOnce(c, rendered)
	if len(drawn) != 1 || drawn[0] != "ghosty" {
		t.Fatalf("first tick drew %v, want the peer that just sent a state", drawn)
	}

	// It goes quiet. No Leave arrives -- that is the whole scenario.
	time.Sleep(150 * time.Millisecond)

	drawn, despawned := renderOnce(c, rendered)
	if len(drawn) != 0 {
		t.Fatalf("a peer silent for longer than RemoteStaleAfter was still drawn: %v", drawn)
	}
	if len(despawned) != 1 || despawned[0] != "ghosty" {
		t.Fatalf("despawned %v, want the silent peer -- a ghost nobody is updating must not stand there forever", despawned)
	}
	if got := c.Stats().RemotesAgedOut; got != 1 {
		t.Fatalf("RemotesAgedOut = %d, want 1", got)
	}
}

// TestAPeerThatKeepsSendingIsNeverAgedOut, however still it stands: change suppression spaces an idle player's states
// one keepalive apart, so the margin between that and the timeout has to be real.
func TestAPeerThatKeepsSendingIsNeverAgedOut(t *testing.T) {
	c := New()
	c.InterpolationDelay = 0
	c.RemoteStaleAfter = 100 * time.Millisecond
	c.playerID = "me"
	c.roster = map[string]int64{"steady": 0}

	rendered := map[string]bool{}
	for i := 0; i < 12; i++ {
		// The same position every time: standing still is not silence.
		c.storeRemoteState(protocol.State{
			PlayerID: "steady", AreaID: "a", Position: []float64{5, 5}, Timestamp: c.nowMs(),
		})
		drawn, despawned := renderOnce(c, rendered)
		if len(despawned) != 0 {
			t.Fatalf("iteration %d despawned %v -- a peer that is sending must never be aged out", i, despawned)
		}
		if len(drawn) != 1 {
			t.Fatalf("iteration %d drew %v, want the peer", i, drawn)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestAgingOutCanBeDisabled: a negative RemoteStaleAfter never ages out, so a session diagnosing something else can
// rule aging out as a cause.
func TestAgingOutCanBeDisabled(t *testing.T) {
	c := New()
	c.InterpolationDelay = 0
	c.RemoteStaleAfter = -1
	c.playerID = "me"
	c.roster = map[string]int64{"frozen": 0}

	c.storeRemoteState(protocol.State{
		PlayerID: "frozen", AreaID: "a", Position: []float64{1, 2}, Timestamp: c.nowMs(),
	})
	rendered := map[string]bool{}
	renderOnce(c, rendered)
	time.Sleep(120 * time.Millisecond)

	drawn, despawned := renderOnce(c, rendered)
	if len(despawned) != 0 {
		t.Fatalf("despawned %v with aging out disabled", despawned)
	}
	if len(drawn) != 1 {
		t.Fatalf("drew %v with aging out disabled, want the peer held", drawn)
	}
}
