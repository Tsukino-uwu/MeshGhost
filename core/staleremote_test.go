package core

// A peer that stops sending must stop being drawn.
//
// Found live 2026-08-28: the user saw "multiple static ghosts" accumulate in a
// running game, one per core restart. Each restarted core joined the relay as a
// NEW player id, and the old id simply stopped sending -- it never left, so
// nothing dropped it, and remoteBuffer.at happily returned its last sample
// forever. The ghosts stood there permanently.

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// renderOnce drives one render tick and reports which ids were rendered and
// which were despawned, the same way an adapter frame does.
func renderOnce(c *Core, rendered map[string]bool) (drawn []string, despawned []string) {
	c.tickRenders(rendered,
		func(id string, st protocol.State) { drawn = append(drawn, id) },
		func(id string) { despawned = append(despawned, id) },
	)
	return drawn, despawned
}

func TestASilentPeerIsDespawnedRatherThanLeftStanding(t *testing.T) {
	c := New()
	c.InterpolationDelay = 0
	c.RemoteStaleAfter = 100 * time.Millisecond
	c.playerID = "me"
	c.roster = map[string]struct{}{"ghosty": {}}

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

// The other half, and the one that would break real sessions if the timeout
// were too eager: a peer that keeps sending is never dropped, however still it
// is standing. Change suppression means an idle player's states arrive one
// keepalive apart rather than every frame, so the margin between the two has to
// be real.
func TestAPeerThatKeepsSendingIsNeverAgedOut(t *testing.T) {
	c := New()
	c.InterpolationDelay = 0
	c.RemoteStaleAfter = 100 * time.Millisecond
	c.playerID = "me"
	c.roster = map[string]struct{}{"steady": {}}

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

// Negative means "never age out", i.e. exactly what this Core did before the
// timeout existed -- kept so a session can rule the new behaviour out when
// diagnosing something else.
func TestAgingOutCanBeDisabled(t *testing.T) {
	c := New()
	c.InterpolationDelay = 0
	c.RemoteStaleAfter = -1
	c.playerID = "me"
	c.roster = map[string]struct{}{"frozen": {}}

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
