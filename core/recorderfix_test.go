package core

// Recorder failure paths that must not leave the player with a wrong picture: a lit indicator over a dead recording, a
// frozen game, or a corpse file the next replay_last picks over a real clip.

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestAFailedRecordingWriteTellsTheAdapter: when the disk fills or the folder goes away mid-run, the core stops writing
// and tells the adapter, or the on-screen indicator stays lit over a lost run, since the console ships hidden. The
// failure is made by creating the recorder's own file behind its back: it is opened O_EXCL at the first sample, so that
// open fails on every platform. What is under test is the response to any write error.
func TestAFailedRecordingWriteTellsTheAdapter(t *testing.T) {
	// Set before the bridge serves: the attach path reads ReplayDir on the bridge goroutine.
	dir := t.TempDir()
	c, _, fa := startLocalPeerCoreWith(t, func(c *Core) { c.ReplayDir = dir })

	path, err := c.StartRecording()
	if err != nil {
		t.Fatalf("start recording: %v", err)
	}
	waitRecordingState(t, fa, true)

	if err := os.WriteFile(path, []byte("in the way\n"), 0o644); err != nil {
		t.Fatalf("occupy the recording path: %v", err)
	}

	st := protocol.State{AreaID: "route-111", Position: []float64{1, 2, 3}}
	c.recordLocal(&st)

	if c.Recording() {
		t.Fatalf("the recorder is still armed after a failed write")
	}
	off := waitRecordingState(t, fa, false)
	if off.StartedUnixMs != 0 {
		t.Fatalf("the stop push carried a start time: %+v", off)
	}
}

// TestAnUnreadableReplayFolderDoesNotSpin: a stat error other than not-exist (a permission denial, a disconnected
// network share) must end replayFileName's search, which holds c.rec.mu, taken by recordLocal on every adapter frame.
// StartRecording runs on its own goroutine, so a spin is a reported failure rather than a hung test binary.
func TestAnUnreadableReplayFolderDoesNotSpin(t *testing.T) {
	denied := errors.New("access is denied")
	old := replayStat
	replayStat = func(string) (os.FileInfo, error) { return nil, denied }
	t.Cleanup(func() { replayStat = old })

	c := New()
	c.ReplayDir = t.TempDir()

	type result struct {
		path string
		err  error
	}
	done := make(chan result, 1)
	go func() {
		p, err := c.StartRecording()
		done <- result{p, err}
	}()

	select {
	case got := <-done:
		if !errors.Is(got.err, denied) {
			t.Fatalf("want the stat error back, got path %q err %v", got.path, got.err)
		}
	case <-time.After(testTimeout):
		t.Fatalf("StartRecording never returned: replayFileName is spinning on a stat error")
	}
	if c.Recording() {
		t.Fatalf("the tap is armed after a start that failed")
	}
}

// TestReplayFileNameGivesUpOnACrowdedFolder is the other half of the bound: every candidate name exists, which no stat
// error ends. One core writes one recording at a time, so a folder that says yes a hundred times is not believed.
func TestReplayFileNameGivesUpOnACrowdedFolder(t *testing.T) {
	old := replayStat
	replayStat = func(string) (os.FileInfo, error) { return nil, nil }
	t.Cleanup(func() { replayStat = old })

	done := make(chan error, 1)
	go func() {
		_, err := replayFileName(t.TempDir(), "rec", time.Now(), false)
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "no free name") {
			t.Fatalf("want a give-up error, got %v", err)
		}
	case <-time.After(testTimeout):
		t.Fatalf("replayFileName never returned on a folder where every name exists")
	}
}

// TestAFailedSaveLastLeavesNoFileBehind: a failed SaveLast removes its partial last-<stamp> file, since replayLast
// picks the newest file by mod time and the player's next replay_last would play nothing. The write fails on an
// orientation that is not valid JSON: opaque to the core, json.Marshal refuses it at the sample line, after the header
// is written.
func TestAFailedSaveLastLeavesNoFileBehind(t *testing.T) {
	dir := t.TempDir()
	c := New()
	c.ReplayDir = dir
	c.SaveLastSpan = 10 * time.Second
	c.SetRingSpan(c.SaveLastSpan)
	c.ring.add(protocol.State{
		Timestamp:   1000,
		AreaID:      "dungeon",
		Position:    []float64{1, 2, 3},
		Orientation: []byte("{not json"),
	})

	if _, _, err := c.SaveLast(); err == nil {
		t.Fatalf("SaveLast reported success on an unmarshalable sample")
	}
	left, err := filepath.Glob(filepath.Join(dir, "last-*"))
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(left) != 0 {
		t.Fatalf("a partial save-last file was left behind: %v", left)
	}
}
