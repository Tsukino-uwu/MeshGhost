package core

// E6 from the 2026-09-07 review: aging a peer out dropped its interpolation
// buffer and left its roster seat and its nametag behind. The roster is capped
// (protocol.MaxRosterSize), and admitToRosterLocked refuses a full one in
// silence -- so on a transport where peers vanish without a goodbye, which is
// the case aging out exists for, a long session eventually stops showing new
// arrivals and refuses the player's own chasers and replays, with no log line
// and PeersKnown pinned at the cap.

import (
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func TestAgingAPeerOutGivesBackItsRosterSeat(t *testing.T) {
	c := New()
	wall := time.Now().UnixMilli()
	// Comfortably past DefaultRemoteStaleAfter, and stamped in the past
	// because staleness is judged against this machine's clock.
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
	// Before the fix: 1 and 1.
	if seats != 0 {
		t.Errorf("roster still holds %d seat(s) for a peer that aged out", seats)
	}
	// The nametag is KEPT since 2026-09-09: an aged-out peer is usually a
	// paused emulator that comes back under the same id without a Join, and
	// a genuinely reused id always arrives with its own Join, which stores
	// the new name unconditionally (a Leave is where a name is dropped).
	if names != 1 {
		t.Errorf("remoteNames holds %d nametag(s) for a peer that aged out, want 1 kept for its return", names)
	}
	if known := c.Stats().PeersKnown; known != 0 {
		t.Errorf("PeersKnown = %d after the only peer aged out, want 0", known)
	}
}

// The symptom itself, at the size it bites: a full roster's worth of peers that
// all went quiet must not lock the room shut.
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
	// Before the fix: refused, and every join after it for the rest of the
	// session -- new players simply never appear.
	if !admitted {
		t.Fatal("a newcomer was refused a roster seat after 512 peers aged out")
	}
}
