package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// renderX is the x of the newest render_remote for id, or -1.
func renderX(fa *fakeAdapter, id string) float64 {
	m, ok := fa.renderMsgOf(id)
	if !ok || len(m.State.Position) == 0 {
		return -1
	}
	return m.State.Position[0]
}

// drainDespawns empties the despawn channel and returns how many were for id.
func drainDespawns(fa *fakeAdapter, id string) int {
	n := 0
	for {
		select {
		case got := <-fa.despawns:
			if got == id {
				n++
			}
		default:
			return n
		}
	}
}

// playingCore starts a 4s clip (x = 0..39, 100ms apart) at 1x and pumps until
// it has rendered past x=5, so a seek has somewhere to go from.
func playingCore(t *testing.T, hdr map[string]any) (*Core, *fakeAdapter, string) {
	t.Helper()
	c, fa := replayCore(t)
	c.ReplaySeek = 1 * time.Second
	writeActive(t, c, "seek.ndjson", clipBytes(hdr, walkStates(40, 100)))
	c.StartReplays()
	const id = "replay:seek.ndjson"
	pumpUntil(t, fa, func() bool { return renderX(fa, id) >= 5 }, "the clip to reach x=5")
	drainDespawns(fa, id)
	return c, fa, id
}

// TestRestartIsASeamBackToTheTop: restart despawns the ghost and the next
// render is from the top of the clip.
func TestRestartIsASeamBackToTheTop(t *testing.T) {
	c, fa, id := playingCore(t, nil)
	if err := c.ReplayControl(ReplayRestart, 0); err != nil {
		t.Fatal(err)
	}
	pumpUntil(t, fa, func() bool { return drainDespawns(fa, id) > 0 }, "the seam's despawn")
	pumpUntil(t, fa, func() bool { x := renderX(fa, id); return x >= 0 && x < 3 }, "a render from the top after restart")
}

// TestRewindAndFastForwardMoveTheClipTime: rewind lands earlier than where
// the ghost was, fast-forward later, each through a seam; fast-forward past
// the end of a non-looping clip ends it, and a restart brings it back.
func TestRewindAndFastForwardMoveTheClipTime(t *testing.T) {
	c, fa, id := playingCore(t, nil)
	pumpUntil(t, fa, func() bool { return renderX(fa, id) >= 12 }, "x=12")
	before := renderX(fa, id)
	if err := c.ReplayControl(ReplayRewind, 1); err != nil { // 1s = 10 samples back
		t.Fatal(err)
	}
	pumpUntil(t, fa, func() bool { return drainDespawns(fa, id) > 0 }, "the rewind seam")
	pumpUntil(t, fa, func() bool { x := renderX(fa, id); return x >= 0 && x < before-5 }, "a render well before where the ghost was")

	at := renderX(fa, id)
	if err := c.ReplayControl(ReplayFastForward, 0); err != nil { // the configured 1s
		t.Fatal(err)
	}
	pumpUntil(t, fa, func() bool { return drainDespawns(fa, id) > 0 }, "the fast-forward seam")
	pumpUntil(t, fa, func() bool { return renderX(fa, id) >= at+8 }, "a render well after where the ghost was")

	if err := c.ReplayControl(ReplayFastForward, 60); err != nil {
		t.Fatal(err)
	}
	pumpUntil(t, fa, func() bool { return drainDespawns(fa, id) > 0 }, "the clip to end after fast-forwarding past it")
	c.replayMu.Lock()
	p := c.replays[id]
	c.replayMu.Unlock()
	select {
	case <-p.done:
	case <-time.After(testTimeout):
		t.Fatal("the player goroutine did not finish after fast-forwarding past the end")
	}
	// A finished, non-looping clip comes back on restart.
	if err := c.ReplayControl(ReplayRestart, 0); err != nil {
		t.Fatal(err)
	}
	pumpUntil(t, fa, func() bool { x := renderX(fa, id); return x >= 0 && x < 3 }, "the finished clip to play again from the top")
}

// TestReplayControlOverTheBridge: the adapter's own key reaches the same
// action through replay_control, and a bad action is logged, not fatal.
func TestReplayControlOverTheBridge(t *testing.T) {
	_, fa, id := playingCore(t, nil)
	send := func(action string, seconds int) {
		payload, _ := json.Marshal(bridge.ReplayControl{Action: action, Seconds: seconds})
		env, _ := json.Marshal(bridge.Envelope{Type: bridge.TypeReplayControl, Payload: payload})
		if err := fa.conn.Send(env); err != nil {
			t.Fatal(err)
		}
	}
	send("nonsense", 0)
	send("restart", 0)
	pumpUntil(t, fa, func() bool { return drainDespawns(fa, id) > 0 }, "the restart seam requested over the bridge")
	pumpUntil(t, fa, func() bool { x := renderX(fa, id); return x >= 0 && x < 3 }, "a render from the top")
}

// TestReplayLastPlaysTheNewestRecordingWithoutMovingIt: two files in the
// library, the newer one plays, the file stays where it was, and pressing it
// again restarts rather than doubling.
func TestReplayLastPlaysTheNewestRecordingWithoutMovingIt(t *testing.T) {
	c, fa := replayCore(t)
	if err := os.MkdirAll(c.ReplayDir, 0o755); err != nil {
		t.Fatal(err)
	}
	older := filepath.Join(c.ReplayDir, "rec-old.ndjson")
	newer := filepath.Join(c.ReplayDir, "rec-new.ndjson")
	os.WriteFile(older, clipBytes(map[string]any{"name": "Old"}, walkStates(30, 100)), 0o644)
	os.WriteFile(newer, clipBytes(map[string]any{"name": "New"}, walkStates(30, 100)), 0o644)
	past := time.Now().Add(-time.Hour)
	os.Chtimes(older, past, past)

	if err := c.ReplayControl(ReplayLast, 0); err != nil {
		t.Fatal(err)
	}
	pumpUntil(t, fa, func() bool { return renderX(fa, "replay:rec-new.ndjson") >= 3 }, "the newest recording to play")
	if _, ok := fa.renderMsgOf("replay:rec-old.ndjson"); ok {
		t.Fatal("the older recording played too")
	}
	if _, err := os.Stat(newer); err != nil {
		t.Fatalf("replay_last moved the file: %v", err)
	}
	if err := c.ReplayControl(ReplayLast, 0); err != nil {
		t.Fatal(err)
	}
	pumpUntil(t, fa, func() bool { return drainDespawns(fa, "replay:rec-new.ndjson") > 0 }, "the second press to restart it")
	if c.ActiveReplays() != 1 {
		t.Fatalf("ActiveReplays = %d, want 1 (a second press restarts, never doubles)", c.ActiveReplays())
	}
}

// TestReplayControlRecordActions: the record actions route to the recorder,
// save_last says it is not built, and seeks with nothing loaded say so.
func TestReplayControlRecordActions(t *testing.T) {
	c := recordingCore(t)
	if err := c.ReplayControl(ReplayRewind, 0); err == nil {
		t.Fatal("rewind with no replay loaded should say so")
	}
	if err := c.ReplayControl(ReplayRecordToggle, 0); err != nil || !c.Recording() {
		t.Fatalf("toggle did not start recording: %v", err)
	}
	if err := c.ReplayControl(ReplayRecordStart, 0); err == nil {
		t.Fatal("record_start while recording should be refused")
	}
	if err := c.ReplayControl(ReplayRecordToggle, 0); err != nil || c.Recording() {
		t.Fatalf("toggle did not stop recording: %v", err)
	}
	if err := c.ReplayControl(ReplaySaveLast, 0); err == nil {
		t.Fatal("save_last with an empty ring should say there is nothing to save")
	}
	if err := c.ReplayControl(ReplayAction("dance"), 0); err == nil {
		t.Fatal("an unknown action should be an error")
	}
	c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{0, 0}})
}
