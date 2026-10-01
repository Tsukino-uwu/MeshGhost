package core

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestReplayLastPlaysTheRecordingYouJustFinished: play, stop, then replay, with nothing moved into replay/active; the
// newest file in the folder plays.
func TestReplayLastPlaysTheRecordingYouJustFinished(t *testing.T) {
	c, fa := replayCore(t)
	if _, err := c.StartRecording(); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 50; i++ {
		c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{float64(i), 0}, Anim: "run"})
	}
	if _, n, err := c.StopRecording(); err != nil || n != 50 {
		t.Fatalf("StopRecording = %d, %v", n, err)
	}
	if err := c.replayLast(); err != nil {
		t.Fatalf("replay_last on the recording just finished: %v", err)
	}
	c.launchPendingReplays()
	pumpUntil(t, fa, func() bool {
		fa.mu.Lock()
		defer fa.mu.Unlock()
		for id := range fa.rendered {
			if strings.HasPrefix(id, localPeerReplayPrefix) {
				return true
			}
		}
		return false
	}, "the just-finished recording to play as a ghost")
}

// TestReplayLastWorksWhileStillRecording: the recorder's buffer flushes when it fills, mid-line, so an open recording
// (or one a crash left) ends in a partial line and must still play what it has.
func TestReplayLastWorksWhileStillRecording(t *testing.T) {
	c, _ := replayCore(t)
	if _, err := c.StartRecording(); err != nil {
		t.Fatal(err)
	}
	// Enough bulk to make the writer flush mid-line at least once.
	for i := 0; i < 4000; i++ {
		c.forwardLocalState(&protocol.State{
			AreaID: "a", Position: []float64{float64(i), 1.5, 2.5}, Anim: "run",
			Extras: map[string]any{"h_speed": float64(i), "pad": strings.Repeat("x", 40)},
		})
	}
	if err := c.replayLast(); err != nil {
		t.Fatalf("replay_last while still recording: %v", err)
	}
	if _, _, err := c.StopRecording(); err != nil {
		t.Fatal(err)
	}
}

// TestATruncatedLastLineLosesOnlyThatLine, while a bad line anywhere else still refuses the file, so the tolerance is
// not a licence to accept garbage.
func TestATruncatedLastLineLosesOnlyThatLine(t *testing.T) {
	dir := t.TempDir()

	whole := clipBytes(map[string]any{"name": "PB"}, walkStates(10, 10))
	cut := filepath.Join(dir, "cut.ndjson")
	if err := os.WriteFile(cut, append(whole, []byte(`{"seq":11,"timestamp":1000100,"area_id":"a","posit`)...), 0o644); err != nil {
		t.Fatal(err)
	}
	clip, err := loadReplay(cut, true)
	if err != nil {
		t.Fatalf("a file with a half-written last line did not load: %v", err)
	}
	if len(clip.samples) != 10 {
		t.Fatalf("got %d samples, want the 10 whole ones", len(clip.samples))
	}

	middle := filepath.Join(dir, "middle.ndjson")
	lines := strings.SplitAfter(string(whole), "\n")
	lines[5] = "{\"seq\":5,\"broken\":\n"
	if err := os.WriteFile(middle, []byte(strings.Join(lines, "")), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadReplay(middle, true); err == nil {
		t.Fatal("a corrupt line in the MIDDLE was accepted; only a truncated final line may be dropped")
	}
}

// TestReplayLastIsNotCappedByReplaysThatAlreadyFinished: finished players are pruned before the cap counts c.replays.
func TestReplayLastIsNotCappedByReplaysThatAlreadyFinished(t *testing.T) {
	c, fa := replayCore(t)
	if _, err := c.StartRecording(); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 20; i++ {
		c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{float64(i), 0}, Anim: "run"})
	}
	if _, _, err := c.StopRecording(); err != nil {
		t.Fatal(err)
	}
	// Sixteen finished players, what sixteen record/replay cycles leave behind; a closed done is all pruning reads.
	c.replayMu.Lock()
	if c.replays == nil {
		c.replays = make(map[string]*replayPlayer)
	}
	for i := 0; i < 16; i++ {
		id := localPeerReplayPrefix + "finished-" + strconv.Itoa(i) + ".ndjson"
		p := newReplayPlayer(c, id, &replayClip{})
		close(p.done)
		c.replays[id] = p
	}
	c.replayMu.Unlock()

	if err := c.replayLast(); err != nil {
		t.Fatalf("replay_last refused with %d finished players in the map: %v", 16, err)
	}
	c.launchPendingReplays()
	pumpUntil(t, fa, func() bool {
		fa.mu.Lock()
		defer fa.mu.Unlock()
		for id := range fa.rendered {
			if strings.HasPrefix(id, localPeerReplayPrefix) {
				return true
			}
		}
		return false
	}, "the new recording to play despite sixteen finished replays")
	c.replayMu.Lock()
	live := len(c.replays)
	c.replayMu.Unlock()
	if live != 1 {
		t.Fatalf("c.replays holds %d entries after pruning; want 1 (the one that is playing)", live)
	}
}
