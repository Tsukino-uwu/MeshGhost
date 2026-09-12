package core

// B1 from the 2026-09-12 adversarial review (P3a-1 + P3b-1): the two maps that
// shadow the roster -- c.remoteNames and c.agedOut -- had no bound and no
// teardown, so a relay could make them grow for the life of the core process.
//
// WHY THAT IS A BRIDGE KILL AND NOT A MEMORY LEAK. pushRemoteNames hands a
// freshly attached adapter one remote_name per known nametag, and remote_name
// does not coalesce (only renders do). Past adapterQueueCap the writer declares
// the adapter stuck rather than slow, closes its socket and runs the full
// teardown: every ghost, the chasers, the replays and any recording in
// progress. Nothing about the accumulation is undone by the disconnect that
// follows, so the next game launch attaches, floods and dies the same way --
// for the life of the core process, with the game showing only a bridge that
// dropped.
//
// Two routes fed it, and neither needs a protocol violation:
//   - Welcome.Nametags, a relay-filled map whose keys the protocol never ties
//     to Welcome.Roster, stored uncapped for any id at all;
//   - join / one state / go quiet, cycled: the age-out gives the roster seat
//     back and deliberately KEEPS the nametag for the peer's return, so the
//     seat is reusable while the memory of it never is.

import (
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// Route one. The roster is already capped, so membership IS the bound.
func TestAWelcomeNametagForSomebodyNotInTheRoomIsRefused(t *testing.T) {
	c := New()

	c.mu.Lock()
	c.admitToRosterLocked("really-here")
	c.mu.Unlock()

	names := map[string]protocol.Nametag{"really-here": {Name: "Here"}}
	// Comfortably past MaxRosterSize, which is the point: the roster merge is
	// capped and this map was not, so the cap could be walked around by
	// putting the ids in the other field.
	for i := 0; i < 4*protocol.MaxRosterSize; i++ {
		names[fmt.Sprintf("never-joined-%d", i)] = protocol.Nametag{Name: "Nobody"}
	}
	c.storeRosterNames(names)

	got := c.remoteNamesSnapshot()
	// Before the fix: 2049.
	if len(got) != 1 {
		t.Fatalf("stored %d nametag(s) from a welcome whose roster holds one player, want 1 -- "+
			"every extra is a non-coalescing remote_name charged to the next adapter that attaches",
			len(got))
	}
	if tag := got["really-here"]; tag.Name != "Here" {
		t.Fatalf("the one player actually in the room got %q, want %q", tag.Name, "Here")
	}
}

// Route two, driven at the size it bites. Each pass is a legal join, one legal
// state and then silence -- no oversized field, no bad type, nothing a relay
// could not do by accident.
func TestPeersCyclingThroughTheAgeOutCannotGrowTheNameMapForever(t *testing.T) {
	c := New()
	wall := time.Now().UnixMilli()
	// Stamped comfortably past DefaultRemoteStaleAfter: staleness is judged
	// against this machine's clock, so one render tick ages each peer out.
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

	// Before the fix: 1536 and 1536, climbing with every cycle and stopping
	// only when the relay got bored.
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

// And the teardown, which is what turned an accumulation into a bill the NEXT
// game launch pays. The local half of this is the whole reason the clear is a
// filtered loop and not `c.remoteNames = nil`.
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

	// A ghost this core invented. It is fed by a goroutine in this process and
	// survives the relay dropping, so its tag must survive with it.
	if !c.admitLocalPeer(localPeerReplayPrefix+"1", protocol.Nametag{Name: "My Replay"}) {
		t.Fatal("could not admit a local replay peer")
	}

	c.mu.Lock()
	c.forgetRelaySessionLocked()
	remembered := len(c.agedOut)
	c.mu.Unlock()

	got := c.remoteNamesSnapshot()
	// Before the fix: all four survived, and pushRemoteNames handed every one
	// of them to the next adapter to attach.
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
