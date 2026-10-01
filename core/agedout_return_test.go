package core

// A peer aged out for silence, most often a paused emulator window, retakes its roster seat on its next fresh state:
// the relay never saw it leave, so no Join comes.

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func TestAPeerThatAgedOutIsBackOnItsNextFreshState(t *testing.T) {
	c := New()
	wall := time.Now().UnixMilli()
	gone := wall - 10_000 // past DefaultRemoteStaleAfter, by this machine's clock

	c.mu.Lock()
	c.admitToRosterLocked("paused")
	c.mu.Unlock()
	c.storeRemoteName("paused", &protocol.Nametag{Name: "Paused"})
	c.storeRemoteState(protocol.State{PlayerID: "paused", Timestamp: gone, AreaID: "town", Position: []float64{1, 2}})
	if got, _ := c.remoteStatesAt(wall); len(got) != 0 {
		t.Fatalf("a peer 10s silent still rendered (%d states)", len(got))
	}
	if aged := c.Stats().RemotesAgedOut; aged != 1 {
		t.Fatalf("RemotesAgedOut = %d, want 1", aged)
	}

	// The window is unpaused: the same id sends a fresh sample, and no Join.
	c.storeRemoteState(protocol.State{PlayerID: "paused", Timestamp: wall, AreaID: "town", Position: []float64{3, 4}})
	c.storeRemoteState(protocol.State{PlayerID: "paused", Timestamp: wall + 50, AreaID: "town", Position: []float64{3, 4}})

	got, _ := c.remoteStatesAt(wall + 500)
	if len(got) != 1 {
		t.Fatalf("a peer that resumed sending renders %d states, want 1 -- it was refused for lacking a roster seat", len(got))
	}
	c.mu.Lock()
	_, seated := c.roster["paused"]
	name, named := c.remoteNames["paused"]
	_, stillAged := c.agedOut["paused"]
	c.mu.Unlock()
	if !seated {
		t.Error("the returning peer holds no roster seat")
	}
	if !named || name.Name != "Paused" {
		t.Errorf("the returning peer's nametag is %q/%v, want \"Paused\" kept across the age-out", name.Name, named)
	}
	if stillAged {
		t.Error("the returning peer is still marked aged-out")
	}
	if back := c.Stats().RemotesReturned; back != 1 {
		t.Errorf("RemotesReturned = %d, want 1", back)
	}
}

func TestAnIdNeverAdmittedIsStillRefusedAfterOthersAgedOut(t *testing.T) {
	c := New()
	wall := time.Now().UnixMilli()

	c.mu.Lock()
	c.admitToRosterLocked("known")
	c.mu.Unlock()
	c.storeRemoteState(protocol.State{PlayerID: "known", Timestamp: wall - 10_000, AreaID: "town", Position: []float64{1, 2}})
	c.remoteStatesAt(wall) // ages "known" out

	c.storeRemoteState(protocol.State{PlayerID: "stranger", Timestamp: wall, AreaID: "town", Position: []float64{1, 2}})
	c.storeRemoteState(protocol.State{PlayerID: "stranger", Timestamp: wall + 50, AreaID: "town", Position: []float64{1, 2}})
	if got, _ := c.remoteStatesAt(wall + 500); len(got) != 0 {
		t.Fatalf("an id the relay never admitted rendered (%d states)", len(got))
	}
}

// TestALeaveClearsTheAgedOutMark: a Leave is the relay letting the id go, so whoever gets it next must arrive with a
// Join.
func TestALeaveClearsTheAgedOutMark(t *testing.T) {
	c := New()
	wall := time.Now().UnixMilli()

	c.mu.Lock()
	c.admitToRosterLocked("gone")
	c.mu.Unlock()
	c.storeRemoteState(protocol.State{PlayerID: "gone", Timestamp: wall - 10_000, AreaID: "town", Position: []float64{1, 2}})
	c.remoteStatesAt(wall)

	c.mu.Lock()
	delete(c.roster, "gone")
	delete(c.remoteNames, "gone")
	delete(c.agedOut, "gone") // what the Leave handler does (relaysession.go)
	c.mu.Unlock()
	c.dropRemote("gone")

	c.storeRemoteState(protocol.State{PlayerID: "gone", Timestamp: wall, AreaID: "town", Position: []float64{1, 2}})
	c.storeRemoteState(protocol.State{PlayerID: "gone", Timestamp: wall + 50, AreaID: "town", Position: []float64{1, 2}})
	if got, _ := c.remoteStatesAt(wall + 500); len(got) != 0 {
		t.Fatalf("an id the relay released rendered without a Join (%d states)", len(got))
	}
}
