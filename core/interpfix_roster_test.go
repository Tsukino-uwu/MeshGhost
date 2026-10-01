package core

// Aging a peer out gives back its roster seat: the roster is capped and admitToRosterLocked refuses a full one in
// silence, so seats kept by peers that vanished without a goodbye would refuse every new arrival, chasers and replays.

import (
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func TestAgingAPeerOutGivesBackItsRosterSeat(t *testing.T) {
	c := New()
	wall := time.Now().UnixMilli()
	// Past DefaultRemoteStaleAfter, stamped in the past because staleness is judged against this machine's clock.
	gone := wall - 10_000

	c.mu.Lock()
	c.admitToRosterLocked("quiet")
	c.mu.Unlock()
	c.storeRemoteName("quiet", &protocol.Nametag{Name: "Quiet"})
	c.storeRemoteState(protocol.State{PlayerID: "quiet", Timestamp: gone, AreaID: "town", Position: []float64{1, 2}})

	if got, _ := c.remoteStatesAt(wall); len(got) != 0 {
		t.Fatalf("a peer 10s silent still rendered (%d states)", len(got))
	}

	c.mu.Lock()
	seats, names := len(c.roster), len(c.remoteNames)
	c.mu.Unlock()
	if seats != 0 {
		t.Errorf("roster still holds %d seat(s) for a peer that aged out", seats)
	}
	// The nametag is kept: an aged-out peer is usually a paused emulator that returns under the same id without a
	// Join, while a reused id always arrives with its own Join, which stores the new name.
	if names != 1 {
		t.Errorf("remoteNames holds %d nametag(s) for a peer that aged out, want 1 kept for its return", names)
	}
	if known := c.Stats().PeersKnown; known != 0 {
		t.Errorf("PeersKnown = %d after the only peer aged out, want 0", known)
	}
}

func TestAFullRosterOfAgedOutPeersStillAdmitsANewcomer(t *testing.T) {
	c := New()
	wall := time.Now().UnixMilli()
	gone := wall - 10_000

	for i := 0; i < protocol.MaxRosterSize; i++ {
		id := fmt.Sprintf("gone-%d", i)
		c.mu.Lock()
		if !c.admitToRosterLocked(id) {
			c.mu.Unlock()
			t.Fatalf("could not fill the roster: %s refused at %d", id, i)
		}
		c.mu.Unlock()
		c.storeRemoteState(protocol.State{PlayerID: id, Timestamp: gone, AreaID: "town", Position: []float64{1, 2}})
	}

	c.remoteStatesAt(wall)

	c.mu.Lock()
	admitted := c.admitToRosterLocked("newcomer")
	c.mu.Unlock()
	if !admitted {
		t.Fatal("a newcomer was refused a roster seat after 512 peers aged out")
	}
}
