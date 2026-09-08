package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
)

// inputCore is recordingCore with the input track turned on -- the feature is
// opt-in, so every test here has to ask for it explicitly, which is also the
// assertion that it is off by default.
func inputCore(t *testing.T) *Core {
	t.Helper()
	c := recordingCore(t)
	c.ReplayInputs = true
	return c
}

// batch is one InputSample carrying edges built from (frame, mask) pairs, with
// t tracking the frame so the monotonic checks are satisfied by construction.
func batch(labels []string, pairs ...[2]uint64) bridge.InputSample {
	s := bridge.InputSample{Labels: labels}
	for _, p := range pairs {
		s.Edges = append(s.Edges, bridge.InputEdge{
			F: p[0], T: int64(p[0]) * 16, M: uint32(p[1]),
		})
	}
	return s
}

func TestInputTrackWritesHeaderAndEdges(t *testing.T) {
	c := inputCore(t)
	path, err := c.StartInputRecording("rec-20260908-120000")
	if err != nil {
		t.Fatalf("StartInputRecording: %v", err)
	}
	if filepath.Base(filepath.Dir(path)) != inputsSubdir {
		t.Errorf("track written to %s, want a file in the %q subfolder", path, inputsSubdir)
	}

	// The file appears at the FIRST edge and not before, so a track armed in
	// the main menu leaves nothing behind if the game is quit before play.
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("the file exists before any edge arrived: %v", err)
	}

	c.recordInput(batch([]string{"jump", "attack"}, [2]uint64{1, 1}, [2]uint64{2, 0}))
	if _, _, err := c.StopInputRecording(); err != nil {
		t.Fatalf("StopInputRecording: %v", err)
	}

	track, err := loadInputTrack(path)
	if err != nil {
		t.Fatalf("loadInputTrack: %v", err)
	}
	if track.header.Format != inputFormatVersion {
		t.Errorf("header format %d, want %d", track.header.Format, inputFormatVersion)
	}
	if track.header.RecordingID != "rec-20260908-120000" {
		t.Errorf("recording_id %q, want the id it was started with", track.header.RecordingID)
	}
	if got := track.header.Labels; len(got) != 2 || got[0] != "jump" {
		t.Errorf("labels %v, want the adapter's table carried into the header", got)
	}
	if len(track.edges) != 2 {
		t.Fatalf("got %d edges, want 2", len(track.edges))
	}
	if track.edges[0].M != 1 || track.edges[1].M != 0 {
		t.Errorf("masks %d,%d, want 1,0", track.edges[0].M, track.edges[1].M)
	}
	// F and T are the ADAPTER's, kept verbatim; a one-frame press has to stay
	// one frame apart however the core stamped the batch.
	if track.edges[1].F-track.edges[0].F != 1 {
		t.Errorf("frames %d and %d: the adapter's spacing was not preserved",
			track.edges[0].F, track.edges[1].F)
	}
}

// The whole feature is opt-in, and this is the test that says so: with
// ReplayInputs unset, nothing arms and nothing is written.
func TestInputTrackIsOffUnlessAskedFor(t *testing.T) {
	c := recordingCore(t) // deliberately NOT inputCore
	path, err := c.StartInputRecording("rec-1")
	if err != nil {
		t.Fatalf("StartInputRecording: %v", err)
	}
	if path != "" {
		t.Errorf("started a track at %s with replay.inputs off", path)
	}
	c.recordInput(batch(nil, [2]uint64{1, 1}))
	if c.InputRecording() {
		t.Error("the input tap is armed with replay.inputs off")
	}
	if _, err := os.Stat(filepath.Join(c.ReplayDir, inputsSubdir)); !os.IsNotExist(err) {
		t.Errorf("the inputs folder was created with the feature off: %v", err)
	}
}

// An edge identical to the one before it is suppressed. The adapter should not
// send one; this side must not depend on that.
func TestInputTrackSuppressesIdenticalEdges(t *testing.T) {
	c := inputCore(t)
	path, err := c.StartInputRecording("")
	if err != nil {
		t.Fatalf("StartInputRecording: %v", err)
	}
	c.recordInput(batch(nil,
		[2]uint64{1, 5}, [2]uint64{2, 5}, [2]uint64{3, 5}, [2]uint64{4, 0}))
	if _, _, err := c.StopInputRecording(); err != nil {
		t.Fatalf("StopInputRecording: %v", err)
	}
	track, err := loadInputTrack(path)
	if err != nil {
		t.Fatalf("loadInputTrack: %v", err)
	}
	if len(track.edges) != 2 {
		t.Fatalf("got %d edges, want 2 (three identical masks collapse to one)", len(track.edges))
	}
	if track.edges[0].M != 5 || track.edges[1].M != 0 {
		t.Errorf("masks %d,%d, want 5,0", track.edges[0].M, track.edges[1].M)
	}
}

// The ring is the always-on half: it collects with no file recording at all,
// and save-last drains it after the fact.
func TestSaveLastInputsDrainsTheRingWithNoRecording(t *testing.T) {
	c := inputCore(t)
	c.SaveLastSpan = time.Minute
	c.armInputRing()
	if c.InputRecording() {
		t.Fatal("the file tap is armed, but only the ring should be")
	}
	c.recordInput(batch([]string{"jump"}, [2]uint64{1, 1}, [2]uint64{2, 0}))

	path, n, err := c.SaveLastInputs("rec-42")
	if err != nil {
		t.Fatalf("SaveLastInputs: %v", err)
	}
	if n != 2 {
		t.Errorf("saved %d edges, want 2", n)
	}
	track, err := loadInputTrack(path)
	if err != nil {
		t.Fatalf("loadInputTrack: %v", err)
	}
	if track.header.RecordingID != "rec-42" {
		t.Errorf("recording_id %q, want the id save-last was given", track.header.RecordingID)
	}
	if len(track.edges) != 2 {
		t.Errorf("got %d edges in the file, want 2", len(track.edges))
	}
}

// The ring trims by the newest EDGE's own stamp, not by wall clock, so a game
// that stops sending freezes the ring rather than draining it.
func TestInputRingTrimsByTheNewestEdge(t *testing.T) {
	var r inputRing
	r.setSpan(time.Second)
	for i := 0; i < 5; i++ {
		r.add(inputEdgeLine{Ts: int64(i) * 400, F: uint64(i)})
	}
	got := r.snapshot()
	if len(got) == 0 {
		t.Fatal("the ring is empty")
	}
	// Newest is 1600; the cutoff is 600, so 0 and 400 are gone.
	if got[0].Ts < 600 {
		t.Errorf("oldest kept edge is at %d, want nothing older than 600", got[0].Ts)
	}
	if got[len(got)-1].Ts != 1600 {
		t.Errorf("newest kept edge is at %d, want 1600", got[len(got)-1].Ts)
	}
}

// A recording and its input track carry the SAME id, which is the only thing
// tying the two artefacts of one run together.
func TestRecordingAndInputTrackShareAnID(t *testing.T) {
	c := inputCore(t)
	recPath, err := c.StartRecording()
	if err != nil {
		t.Fatalf("StartRecording: %v", err)
	}
	c.recordInput(batch([]string{"jump"}, [2]uint64{1, 1}))
	inPath := c.inputRec.path
	if _, _, err := c.StopRecording(); err != nil {
		t.Fatalf("StopRecording: %v", err)
	}
	track, err := loadInputTrack(inPath)
	if err != nil {
		t.Fatalf("loadInputTrack: %v", err)
	}
	if want := recordingIDFor(recPath); track.header.RecordingID != want {
		t.Errorf("input track's recording_id is %q, the recording's is %q", track.header.RecordingID, want)
	}
}

func TestRecordingIDStripsEveryExtension(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{filepath.Join("x", "rec-20260908-120000.ndjson"), "rec-20260908-120000"},
		{filepath.Join("x", "rec-20260908-120000.ndjson.gz"), "rec-20260908-120000"},
		{filepath.Join("x", "rec-20260908-120000-2.ndjson"), "rec-20260908-120000-2"},
	} {
		if got := recordingIDFor(tc.in); got != tc.want {
			t.Errorf("recordingIDFor(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
