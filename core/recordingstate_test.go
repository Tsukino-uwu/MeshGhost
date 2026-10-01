package core

// The recording indicator's half of the bridge: the core holds the record hotkey but can never draw, so the adapter
// must learn a recording is running without asking and without a console.

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
			// Attach pushes the current state, so a stale false can sit in front of the one we want.
		case <-deadline:
			t.Fatalf("no recording_state with Recording=%v", want)
		}
	}
}

func TestRecordingStateReachesTheAdapterOnBothEdges(t *testing.T) {
	// Set before the bridge serves: StartReplays reads it on the attach path, on the bridge goroutine.
	c, _, fa := startLocalPeerCoreWith(t, func(c *Core) { c.ReplayDir = t.TempDir() })

	if _, err := c.StartRecording(); err != nil {
		t.Fatalf("start recording: %v", err)
	}
	on := waitRecordingState(t, fa, true)
	// The start time is what lets the adapter show elapsed time without a message per second.
	if on.StartedUnixMs <= 0 {
		t.Fatalf("recording_state true carried no start time: %+v", on)
	}

	if _, _, err := c.StopRecording(); err != nil {
		t.Fatalf("stop recording: %v", err)
	}
	off := waitRecordingState(t, fa, false)
	// Zeroed on stop so an adapter cannot keep counting from a stale start.
	if off.StartedUnixMs != 0 {
		t.Fatalf("recording_state false carried a start time: %+v", off)
	}
}

// TestRecordingStateIsPushedOnChangeOnly: attach pushes the state unconditionally, which is only affordable if a
// repeat never reaches the adapter.
func TestRecordingStateIsPushedOnChangeOnly(t *testing.T) {
	// Set before the bridge serves: StartReplays reads it on the attach path, on the bridge goroutine.
	c, _, fa := startLocalPeerCoreWith(t, func(c *Core) { c.ReplayDir = t.TempDir() })

	if _, err := c.StartRecording(); err != nil {
		t.Fatalf("start recording: %v", err)
	}
	waitRecordingState(t, fa, true)

	// The same state three times, as the attach path would push it on a reconnect.
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
