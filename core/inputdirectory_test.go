package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestReplayScannersIgnoreTheInputTrack is the test that pins the safety
// argument for putting tracks in replay/inputs/ rather than beside the clips.
//
// The argument is a fact about two specific functions, not a convention:
// replayLast plays the newest FILE in ReplayDir (it skips directories), and
// StartReplays reads only ReplayDir/active/. A track in either would be picked
// up and parsed as a clip -- and replayLast in particular chooses by mod time,
// so a freshly written track would win over every real recording the player has.
//
// If a refactor ever makes either scanner descend into subfolders, this fails
// rather than the player's next F11 spawning a ghost from an input file.
func TestReplayScannersIgnoreTheInputTrack(t *testing.T) {
	c := inputCore(t)

	// A real recording for replayLast to find, so the test distinguishes
	// "ignored the track" from "found nothing at all".
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

	// StartReplays reads active/ only. Copy the track in as a bare filename to
	// prove the SUBFOLDER is what protects it, not the "in-" prefix.
	activeDir := filepath.Join(c.ReplayDir, "active")
	if err := os.MkdirAll(activeDir, 0o755); err != nil {
		t.Fatalf("mkdir active: %v", err)
	}
	if n := c.StartReplays(); n != 0 {
		t.Errorf("StartReplays loaded %d clip(s) from an empty active/ -- the inputs subfolder is being scanned", n)
	}
	c.StopReplays()

	// replayLast picks the newest file in the replay folder. The track is
	// newer than the recording, so if directories were descended into it would
	// win -- which is the failure this exists to catch.
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

// A track handed to the CLIP parser is refused with a sentence rather than
// misplayed, which is the belt-and-braces half of the argument above: it
// survives somebody hand-copying a file up one level.
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

	if _, err := loadReplay(path); err == nil {
		t.Fatal("the clip parser accepted an input track")
	} else if !strings.Contains(err.Error(), "meshghost_replay") {
		t.Errorf("refused with %q, want a sentence naming the missing meshghost_replay key", err)
	}
}

// And the reverse: a clip handed to the TRACK parser is refused the same way.
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
