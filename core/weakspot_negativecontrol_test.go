package core

// NEGATIVE ASSERTIONS WITH A POSITIVE CONTROL (2026-09-08).
//
// core's "nothing arrived" assertions were bounded by wall time and nothing
// else: wait 200 ms, read a channel, conclude the message was never sent.
// That shape gets WEAKER as the machine gets slower, so it fails toward PASS
// -- on CI under -race, or on a loaded box, the thing being forbidden can be
// sent a millisecond after the wait ends and the test still reports success.
// Nobody notices, because the failure mode is green.
//
// Two examples of the shape stood in this package on 2026-09-08:
// TestRecordingStateIsPushedOnChangeOnly (200 ms on fa.recordings) and
// TestAPeerWithNoNameIsNeverStored (a 200 ms sleep, then assert the map is
// empty). Both would pass against a core that pushed nothing at all, and the
// second would pass against one whose nametag pipeline was entirely dead.
//
// The fix in both cases is a POSITIVE CONTROL in the same test: make the same
// channel carry something it MUST carry, so "nothing arrived" is bounded by an
// event rather than by a duration, and a silent pipeline fails instead of
// passing. Neither test below sleeps.

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestAnUnchangedRecordingStateIsNotPushedAndTheNextChangeIs is the de-dupe
// assertion bounded by the change that follows it rather than by a stopwatch.
//
// The adapter draws the REC indicator from these pushes, so a repeat is a
// redraw for nothing, and attach pushes the current state unconditionally --
// which is only affordable if it de-dupes. The control is the stop: the very
// next recording_state the adapter receives must be the change to false. If a
// duplicate `true` had been pushed it is that duplicate that arrives here, and
// if the push path were dead altogether nothing arrives and the test fails
// too -- which is the case the 200 ms version could not distinguish from
// success.
func TestAnUnchangedRecordingStateIsNotPushedAndTheNextChangeIs(t *testing.T) {
	// ReplayDir is set BEFORE the bridge serves: StartReplays reads it on the
	// attach path, on the bridge goroutine, and setting it afterwards is a
	// data race CI's -race run caught on 2026-09-05.
	c, _, fa := startLocalPeerCoreWith(t, func(c *Core) { c.ReplayDir = t.TempDir() })

	if _, err := c.StartRecording(); err != nil {
		t.Fatalf("start recording: %v", err)
	}
	waitRecordingState(t, fa, true)

	// Three pushes of the same state, as a reconnect's attach path would do.
	// None may reach the adapter.
	c.pushRecordingState()
	c.pushRecordingState()
	c.pushRecordingState()

	// THE CONTROL. A real change, queued behind those three on the same
	// single-writer queue, so whatever arrives first says which of them was
	// actually sent.
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

// TestAnUnnamedPeerIsStoredNowhileANamedOneIs replaces a sleep-then-assert-empty
// with an ordering argument.
//
// A peer with no name must produce no entry at all rather than an entry with an
// empty name: the adapter answers "should I draw a label?" by absence, and no
// name is the shipped default. Asserting that after a fixed sleep passes just
// as happily against a core that stores no nametags whatsoever, which is a
// live failure mode -- 2026-08-28's defect was precisely a nametag that the
// core knew and the adapter never heard about.
//
// The control is a named peer in the same room. Both peers are already in the
// room before the watcher joins, so both reach it in the SAME Welcome roster,
// on one connection, in one message: when the named one is known, the unnamed
// one has been processed too, and nothing about the machine's speed enters
// into it.
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

	// Same roster, same message: if the named peer is in, the unnamed one has
	// been considered and rejected.
	if tag, ok := names[unnamedID]; ok {
		t.Fatalf("a peer who set no name was stored as %+v -- the adapter decides whether to draw "+
			"a label by absence, so an empty entry is a blank label rather than none", tag)
	}
	if len(names) != 1 {
		t.Fatalf("the watcher stored %d nametag(s) for a room with one named peer: %v", len(names), names)
	}
}
