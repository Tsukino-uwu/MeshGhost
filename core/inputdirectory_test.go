package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestReplayScannersIgnoreTheInputTrack: tracks in replay/inputs/ are safe only while replayLast skips directories
// and StartReplays reads only active/; replayLast picks by mod time, so a fresh track would beat every recording.
func TestReplayScannersIgnoreTheInputTrack(t *testing.T) {
	c := inputCore(t)

	// A real recording, so "ignored the track" differs from "found nothing at all".
	if _, err := c.StartRecording(); err != nil {
		t.Fatalf("StartRecording: %v", err)
	}
	c.recordLocal(&protocol.State{AreaID: "a", Position: []float64{1, 2}})
	c.recordInput(batch([]string{"jump"}, [2]uint64{1, 1}))
	inPath := c.inputRec.path
	if _, _, err := c.StopRecording(); err != nil {
		t.Fatalf("StopRecording: %v", err)
	}
	if _, err := os.Stat(inPath); err != nil {
		t.Fatalf("the input track was not written: %v", err)
	}

	// An empty active/: StartReplays reads only that folder, so the track in inputs/ must not load.
	activeDir := filepath.Join(c.ReplayDir, "active")
	if err := os.MkdirAll(activeDir, 0o755); err != nil {
		t.Fatalf("mkdir active: %v", err)
	}
	if n := c.StartReplays(); n != 0 {
		t.Errorf("StartReplays loaded %d clip(s) from an empty active/ -- the inputs subfolder is being scanned", n)
	}
	c.StopReplays()

	// The track is newer than the recording, so a replayLast that descended into directories would pick it.
	if err := c.replayLast(); err != nil {
		t.Fatalf("replayLast: %v", err)
	}
	c.replayMu.Lock()
	var picked []string
	for id := range c.replays {
		picked = append(picked, id)
	}
	c.replayMu.Unlock()
	c.StopReplays()
	if len(picked) != 1 {
		t.Fatalf("replayLast started %d ghost(s), want 1", len(picked))
	}
	if strings.Contains(picked[0], "in-") || strings.Contains(picked[0], inputsSubdir) {
		t.Errorf("replayLast picked %q -- that is an input track, not a recording", picked[0])
	}
}

// A track handed to the clip parser is refused with a sentence rather than misplayed, which survives somebody
// hand-copying a file up one level.
func TestInputTrackIsRefusedByTheReplayParser(t *testing.T) {
	c := inputCore(t)
	path, err := c.StartInputRecording("")
	if err != nil {
		t.Fatalf("StartInputRecording: %v", err)
	}
	c.recordInput(batch([]string{"jump"}, [2]uint64{1, 1}))
	if _, _, err := c.StopInputRecording(); err != nil {
		t.Fatalf("StopInputRecording: %v", err)
	}

	if _, err := loadReplay(path, true); err == nil {
		t.Fatal("the clip parser accepted an input track")
	} else if !strings.Contains(err.Error(), "meshghost_replay") {
		t.Errorf("refused with %q, want a sentence naming the missing meshghost_replay key", err)
	}
}

func TestReplayClipIsRefusedByTheInputParser(t *testing.T) {
	c := inputCore(t)
	if _, err := c.StartRecording(); err != nil {
		t.Fatalf("StartRecording: %v", err)
	}
	c.recordLocal(&protocol.State{AreaID: "a", Position: []float64{1, 2}})
	path, _, err := c.StopRecording()
	if err != nil {
		t.Fatalf("StopRecording: %v", err)
	}
	if _, err := loadInputTrack(path); err == nil {
		t.Fatal("the track parser accepted a replay clip")
	} else if !strings.Contains(err.Error(), "meshghost_inputs") {
		t.Errorf("refused with %q, want a sentence naming the missing meshghost_inputs key", err)
	}
}
