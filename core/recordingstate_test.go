package core

// The recording indicator's half of the bridge: does the adapter learn that a
// recording is running, without asking and without a console?
//
// WHY THIS TEST EXISTS. The record hotkey lives in this process (ADR 0048) and
// this process can never draw, so before recording_state the only feedback was a
// log line -- and the user runs with the console hidden: "was unsure if f9 was
// doing something or not when using it. i usually did f9 2-3 times then f11".
// Everything below fails against a core that only logs.

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
)

func waitRecordingState(t *testing.T, fa *fakeAdapter, want bool) bridge.RecordingState {
	t.Helper()
	deadline := time.After(testTimeout)
	for {
		select {
		case rs := <-fa.recordings:
			if rs.Recording == want {
				return rs
			}
			// Not a failure on its own: attach pushes the current state, so a
			// stale `false` can legitimately sit in front of the one we want.
		case <-deadline:
			t.Fatalf("no recording_state with Recording=%v", want)
		}
	}
}

// TestRecordingStateReachesTheAdapterOnBothEdges is the whole feature in one
// test: start and the adapter is told, stop and it is told again.
func TestRecordingStateReachesTheAdapterOnBothEdges(t *testing.T) {
	// The folder is set BEFORE the bridge serves: StartReplays reads it on the
	// attach path, on the bridge goroutine, and setting it afterwards is a data
	// race CI's -race run caught on 2026-09-05 (flaky: the next run passed).
	c, _, fa := startLocalPeerCoreWith(t, func(c *Core) { c.ReplayDir = t.TempDir() })

	if _, err := c.StartRecording(); err != nil {
		t.Fatalf("start recording: %v", err)
	}
	on := waitRecordingState(t, fa, true)
	// The START TIME is the field that makes an elapsed-time display possible
	// without a message per second, so its absence is a real failure rather
	// than a cosmetic one.
	if on.StartedUnixMs <= 0 {
		t.Fatalf("recording_state true carried no start time: %+v", on)
	}

	if _, _, err := c.StopRecording(); err != nil {
		t.Fatalf("stop recording: %v", err)
	}
	off := waitRecordingState(t, fa, false)
	// Zeroed on stop so an adapter cannot keep counting from a stale start --
	// the indicator is off, and a time that ticks under a hidden indicator is
	// the kind of state that resurfaces wrong later.
	if off.StartedUnixMs != 0 {
		t.Fatalf("recording_state false carried a start time: %+v", off)
	}
}

// TestRecordingStateIsPushedOnChangeOnly: the adapter draws from this, so a
// repeat push is a redraw for nothing -- and the state is pushed on attach
// unconditionally, which is only affordable if it de-dupes.
func TestRecordingStateIsPushedOnChangeOnly(t *testing.T) {
	// The folder is set BEFORE the bridge serves: StartReplays reads it on the
	// attach path, on the bridge goroutine, and setting it afterwards is a data
	// race CI's -race run caught on 2026-09-05 (flaky: the next run passed).
	c, _, fa := startLocalPeerCoreWith(t, func(c *Core) { c.ReplayDir = t.TempDir() })

	if _, err := c.StartRecording(); err != nil {
		t.Fatalf("start recording: %v", err)
	}
	waitRecordingState(t, fa, true)

	// Three pushes of the same state, as the attach path would do on a
	// reconnect. None may reach the adapter.
	c.pushRecordingState()
	c.pushRecordingState()
	c.pushRecordingState()

	select {
	case rs := <-fa.recordings:
		t.Fatalf("an unchanged recording_state was pushed again: %+v", rs)
	case <-time.After(200 * time.Millisecond):
	}
	if _, _, err := c.StopRecording(); err != nil {
		t.Fatalf("stop recording: %v", err)
	}
	waitRecordingState(t, fa, false)
}
