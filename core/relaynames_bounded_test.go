package core

// c.remoteNames and c.agedOut shadow the roster, and unbounded they kill the bridge rather than leak: a fresh adapter
// is sent one non-coalescing remote_name per known nametag, and past adapterQueueCap the writer calls it stuck and
// tears the session down, on every game launch after.

import (
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestAWelcomeNametagForSomebodyNotInTheRoomIsRefused: the protocol never ties Welcome.Nametags to the roster, so
// roster membership, already capped, is the bound.
func TestAWelcomeNametagForSomebodyNotInTheRoomIsRefused(t *testing.T) {
	c := New()

	c.mu.Lock()
	c.admitToRosterLocked("really-here")
	c.mu.Unlock()

	names := map[string]protocol.Nametag{"really-here": {Name: "Here"}}
	// Past MaxRosterSize: ids in this field must not walk around the roster's cap.
	for i := 0; i < 4*protocol.MaxRosterSize; i++ {
		names[fmt.Sprintf("never-joined-%d", i)] = protocol.Nametag{Name: "Nobody"}
	}
	c.storeRosterNames(names)

	got := c.remoteNamesSnapshot()
	if len(got) != 1 {
		t.Fatalf("stored %d nametag(s) from a welcome whose roster holds one player, want 1 -- "+
			"every extra is a non-coalescing remote_name charged to the next adapter that attaches",
			len(got))
	}
	if tag := got["really-here"]; tag.Name != "Here" {
		t.Fatalf("the one player actually in the room got %q, want %q", tag.Name, "Here")
	}
}

// TestPeersCyclingThroughTheAgeOutCannotGrowTheNameMapForever: the age-out frees the seat but keeps the nametag for
// the peer's return, so a legal join, one legal state and silence, cycled, must not grow the maps.
func TestPeersCyclingThroughTheAgeOutCannotGrowTheNameMapForever(t *testing.T) {
	c := New()
	wall := time.Now().UnixMilli()
	// Past DefaultRemoteStaleAfter on this machine's clock, so one render tick ages each peer out.
	gone := wall - 10_000

	const cycles = 3 * protocol.MaxRosterSize
	for i := 0; i < cycles; i++ {
		id := fmt.Sprintf("churn-%d", i)
		c.mu.Lock()
		admitted := c.admitToRosterLocked(id)
		c.mu.Unlock()
		if !admitted {
			t.Fatalf("%s was refused a seat at cycle %d -- the age-out should have freed one", id, i)
		}
		c.storeRemoteName(id, &protocol.Nametag{Name: id})
		c.storeRemoteState(protocol.State{
			PlayerID: id, Timestamp: gone, AreaID: "town", Position: []float64{1, 2},
		})
		c.remoteStatesAt(wall)
	}

	c.mu.Lock()
	names, remembered, seats := len(c.remoteNames), len(c.agedOut), len(c.roster)
	c.mu.Unlock()

	if remembered > protocol.MaxRosterSize {
		t.Errorf("agedOut holds %d id(s) after %d join/quiet cycles, want at most %d",
			remembered, cycles, protocol.MaxRosterSize)
	}
	if names > protocol.MaxRosterSize+seats {
		t.Errorf("remoteNames holds %d nametag(s) after %d join/quiet cycles, want at most %d "+
			"(one per remembered id, plus the %d still seated)",
			names, cycles, protocol.MaxRosterSize+seats, seats)
	}
}

// TestDroppingARelaySessionForgetsItsPeersAndKeepsTheCoresOwnGhosts: without the clear the next game launch is sent
// every stale tag; local ghosts' tags survive, which is why the clear is a filtered loop and not
// `c.remoteNames = nil`.
func TestDroppingARelaySessionForgetsItsPeersAndKeepsTheCoresOwnGhosts(t *testing.T) {
	c := New()

	c.mu.Lock()
	c.admitToRosterLocked("peer-1")
	c.admitToRosterLocked("peer-2")
	c.agedOut = map[string]struct{}{"peer-3": {}}
	c.mu.Unlock()
	c.storeRemoteName("peer-1", &protocol.Nametag{Name: "One"})
	c.storeRemoteName("peer-2", &protocol.Nametag{Name: "Two"})
	c.storeRemoteName("peer-3", &protocol.Nametag{Name: "Three"})

	// A ghost this core invented survives the relay dropping, so its tag must too.
	if !c.admitLocalPeer(localPeerReplayPrefix+"1", protocol.Nametag{Name: "My Replay"}) {
		t.Fatal("could not admit a local replay peer")
	}

	c.mu.Lock()
	c.forgetRelaySessionLocked()
	remembered := len(c.agedOut)
	c.mu.Unlock()

	got := c.remoteNamesSnapshot()
	for _, id := range []string{"peer-1", "peer-2", "peer-3"} {
		if _, still := got[id]; still {
			t.Errorf("%s's nametag outlived the relay connection that named it -- "+
				"player_ids are only meaningful inside their own connection", id)
		}
	}
	if remembered != 0 {
		t.Errorf("agedOut holds %d id(s) after the connection that admitted them went away, want 0", remembered)
	}
	if tag, ok := got[localPeerReplayPrefix+"1"]; !ok || tag.Name != "My Replay" {
		t.Errorf("the core's own replay ghost lost its nametag when the relay dropped (got %q, present=%v) -- "+
			"a local ghost has no far side to disconnect from", tag.Name, ok)
	}
}
