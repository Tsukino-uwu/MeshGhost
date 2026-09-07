package core

// Three recorder failure paths that nobody watched, found in the 2026-09-07
// review and fixed on 2026-09-08. All three share a shape: the recorder notices
// something wrong, handles it locally, and leaves the PLAYER with a wrong
// picture -- a lit indicator over a dead recording, a frozen game, or a corpse
// file that the next replay_last picks in preference to a real clip.

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestAFailedRecordingWriteTellsTheAdapter: the disk fills, the USB stick is
// pulled, the folder goes away mid-run. The core stops writing -- and before
// this fix said so only on a console that ships hidden, so the on-screen REC
// indicator stayed lit for the rest of the session and the run was lost in
// silence.
//
// The failure is produced by creating the recorder's own file behind its back:
// the path is decided at StartRecording and opened O_EXCL at the first sample,
// so the first sample's open fails with EEXIST on every platform. That is one
// real member of the class; what is under test is what the core does after ANY
// write error, not which one.
func TestAFailedRecordingWriteTellsTheAdapter(t *testing.T) {
	// Set before the bridge serves, as the other recording tests do: the attach
	// path reads ReplayDir on the bridge goroutine (-race, 2026-09-05).
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

// TestAnUnreadableReplayFolderDoesNotSpin: replayFileName's loop used to exit
// only on os.ErrNotExist, so a permission denial or a disconnected network
// share answered every candidate with the same error and it counted up forever
// -- holding c.rec.mu, which recordLocal wants on every adapter frame, so the
// bridge reader goroutine wedged behind it.
//
// StartRecording is called on its own goroutine so that the pre-fix behaviour
// is a reported failure rather than a hung test binary.
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

// TestReplayFileNameGivesUpOnACrowdedFolder is the other half of the same
// bound: every candidate name answers "exists", which no stat error can end.
// One core writes one recording at a time, so a folder that says yes a hundred
// times is not to be believed and the search has to stop somewhere.
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

// TestAFailedSaveLastLeavesNoFileBehind: SaveLast creates its file O_EXCL and
// used to close-and-return on every error path, leaving a truncated
// last-<stamp>.ndjson in the replay folder -- which replayLast then picks,
// because it takes the NEWEST file by mod time. A .gz cut before its footer is
// refused whole (ADR 0051), so the player's next replay_last plays nothing and
// blames the feature.
//
// The write is failed with an orientation that is not valid JSON: it is opaque
// to the core by contract, carried as json.RawMessage, and json.Marshal refuses
// it at the sample line -- after the header line has already been written, which
// is the partial-file case.
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
