package core

// A "nothing arrived" assertion bounded by wall time passes on a slow machine and against a dead pipeline, so each
// test here bounds it by a positive control on the same channel instead.

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestAnUnchangedRecordingStateIsNotPushedAndTheNextChangeIs: attach pushes the recording state unconditionally,
// which is only affordable if a repeat is dropped. The control is the stop: the next recording_state must be the
// change to false, and a dead push path fails too.
func TestAnUnchangedRecordingStateIsNotPushedAndTheNextChangeIs(t *testing.T) {
	// Before the bridge serves: StartReplays reads ReplayDir on the bridge goroutine's attach path.
	c, _, fa := startLocalPeerCoreWith(t, func(c *Core) { c.ReplayDir = t.TempDir() })

	if _, err := c.StartRecording(); err != nil {
		t.Fatalf("start recording: %v", err)
	}
	waitRecordingState(t, fa, true)

	// Repeats, as a reconnect's attach path would push them; none may reach the adapter.
	c.pushRecordingState()
	c.pushRecordingState()
	c.pushRecordingState()

	// The control, queued behind those on the same single-writer queue, so whatever arrives first says which was sent.
	if _, _, err := c.StopRecording(); err != nil {
		t.Fatalf("stop recording: %v", err)
	}

	select {
	case rs := <-fa.recordings:
		if rs.Recording {
			t.Fatal("the next recording_state the adapter received was another `recording: true` -- " +
				"an unchanged state was pushed again, and the adapter redraws the indicator for nothing")
		}
	case <-time.After(testTimeout):
		t.Fatal("the adapter was never told the recording stopped -- the REC indicator stays lit " +
			"for the rest of the session, and a test that only waited for silence would have " +
			"called this a pass")
	}
}

// TestAnUnnamedPeerIsStoredNowhileANamedOneIs: a peer with no name gets no entry at all, since the adapter decides
// whether to draw a label by absence. The control is a named peer: both reach the watcher in one Welcome roster, so
// once the named one is known the unnamed one has been processed, whatever the machine's speed.
func TestAnUnnamedPeerIsStoredNowhileANamedOneIs(t *testing.T) {
	addr := startRelay(t)

	unnamed, _ := startCore(t, addr, "nametaggame", "room1", "")
	waitForPlayerID(t, unnamed)
	unnamedID := unnamed.PlayerID()

	named, _ := startCore(t, addr, "nametaggame", "room1", "Bob")
	waitForPlayerID(t, named)
	namedID := named.PlayerID()

	watcher, _ := startCore(t, addr, "nametaggame", "room1", "")

	deadline := time.Now().Add(testTimeout)
	var names map[string]protocol.Nametag
	for {
		names = watcher.remoteNamesSnapshot()
		if tag, ok := names[namedID]; ok && tag.Name == "Bob" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the watcher never learned the named peer's tag in %v -- the nametag path is "+
				"not working at all, which is the case an assertion about SILENCE cannot see", testTimeout)
		}
		time.Sleep(5 * time.Millisecond)
	}

	if tag, ok := names[unnamedID]; ok {
		t.Fatalf("a peer who set no name was stored as %+v -- the adapter decides whether to draw "+
			"a label by absence, so an empty entry is a blank label rather than none", tag)
	}
	if len(names) != 1 {
		t.Fatalf("the watcher stored %d nametag(s) for a room with one named peer: %v", len(names), names)
	}
}
