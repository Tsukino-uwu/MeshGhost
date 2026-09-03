package core

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// recordingCore is a Core with no relay (forwardLocalState returns right after
// the tap) and a temp replay folder, so a test exercises exactly the tap.
func recordingCore(t *testing.T) *Core {
	t.Helper()
	c := New()
	c.ReplayDir = filepath.Join(t.TempDir(), "replay")
	c.mu.Lock()
	c.adapterGameID = "emerald"
	c.adapterGameVersion = "v1"
	c.mu.Unlock()
	return c
}

func readReplayLines(t *testing.T, path string) (replayHeader, []protocol.State) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	defer f.Close()
	// Recordings ship gzipped (Core.ReplayGzip), and every reader in the
	// project takes either extension -- so this one does too, rather than
	// pinning the tests to the plain form and letting the shipped shape go
	// untested.
	var src io.Reader = f
	if strings.HasSuffix(path, ".gz") {
		gz, err := gzip.NewReader(f)
		if err != nil {
			t.Fatalf("gunzip %s: %v", path, err)
		}
		defer gz.Close()
		src = gz
	}
	sc := bufio.NewScanner(src)
	var hdr replayHeader
	var states []protocol.State
	for i := 0; sc.Scan(); i++ {
		if i == 0 {
			if err := json.Unmarshal(sc.Bytes(), &hdr); err != nil {
				t.Fatalf("header line: %v", err)
			}
			continue
		}
		var st protocol.State
		if err := json.Unmarshal(sc.Bytes(), &st); err != nil {
			t.Fatalf("line %d: %v", i+1, err)
		}
		states = append(states, st)
	}
	return hdr, states
}

// TestRecordingWritesAHeaderThenOneStatePerLine is the file format: header
// first with the recorder-written facts filled in and the player-editable keys
// at their defaults; then samples with the recorder's own seq, a stamped
// timestamp, no player id, no loss cover -- and no file at all until the first
// non-nil frame, so a recording armed in the main menu starts at gameplay.
func TestRecordingWritesAHeaderThenOneStatePerLine(t *testing.T) {
	c := recordingCore(t)
	path, err := c.StartRecording()
	if err != nil {
		t.Fatal(err)
	}
	if !c.Recording() {
		t.Fatal("Recording() false right after StartRecording")
	}
	c.forwardLocalState(nil)
	c.forwardLocalState(nil)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("file %s exists before the first in-game sample (stat err %v)", path, err)
	}
	for i := 0; i < 5; i++ {
		c.forwardLocalState(&protocol.State{
			PlayerID: "should-be-cleared", Seq: 999, Timestamp: 12345,
			AreaID: "a", Position: []float64{float64(i), 0}, Anim: "run",
			Prev: &protocol.StatePrev{},
		})
	}
	gotPath, written, err := c.StopRecording()
	if err != nil || gotPath != path || written != 5 {
		t.Fatalf("StopRecording = (%q, %d, %v), want (%q, 5, nil)", gotPath, written, err, path)
	}
	if c.Recording() {
		t.Fatal("Recording() true after StopRecording")
	}

	hdr, states := readReplayLines(t, path)
	if hdr.Format != replayFormatVersion || hdr.Game != "emerald" || hdr.GameVersion != "v1" || hdr.ProtocolVersion != protocol.Version || hdr.Recorded == "" {
		t.Fatalf("header facts wrong: %+v", hdr)
	}
	if hdr.Speed != 1.0 || hdr.Anchor != "launch" || hdr.TrimStart != "0s" || hdr.SkipGaps != "0s" || hdr.StartDelay != "0s" || hdr.Loop {
		t.Fatalf("header defaults wrong: %+v", hdr)
	}
	if len(states) != 5 {
		t.Fatalf("got %d state lines, want 5", len(states))
	}
	var lastTs int64
	for i, st := range states {
		if st.Seq != uint64(i+1) || st.PlayerID != "" || st.Prev != nil {
			t.Fatalf("line %d not restamped: %+v", i, st)
		}
		if st.Timestamp < lastTs || st.Timestamp == 12345 {
			t.Fatalf("line %d timestamp %d not stamped by the recorder (prev %d)", i, st.Timestamp, lastTs)
		}
		lastTs = st.Timestamp
		if st.Position[0] != float64(i) || st.Anim != "run" {
			t.Fatalf("line %d lost its content: %+v", i, st)
		}
	}
}

// TestRecordingDedupesIdenticalFramesWithinTheKeepalive: standing still is one
// line per keepalive, not one per frame; anything changed is written at once.
func TestRecordingDedupesIdenticalFramesWithinTheKeepalive(t *testing.T) {
	c := recordingCore(t)
	c.IdleKeepalive = 80 * time.Millisecond
	path, err := c.StartRecording()
	if err != nil {
		t.Fatal(err)
	}
	still := protocol.State{AreaID: "a", Position: []float64{1, 1}, Anim: "idle"}
	for i := 0; i < 20; i++ {
		s := still
		c.forwardLocalState(&s)
	}
	time.Sleep(100 * time.Millisecond)
	s := still
	c.forwardLocalState(&s)
	moved := protocol.State{AreaID: "a", Position: []float64{2, 1}, Anim: "idle"}
	c.forwardLocalState(&moved)
	if _, n, _ := c.StopRecording(); n != 3 {
		t.Fatalf("wrote %d lines, want 3 (first, keepalive restatement, the move)", n)
	}
	_, states := readReplayLines(t, path)
	if len(states) != 3 || states[2].Position[0] != 2 {
		t.Fatalf("file has %d states / last %+v", len(states), states[len(states)-1])
	}
}

// TestRecordingSurvivesAreaChangesAndNilFrames: a full run is one file --
// zone changes and loading-screen gaps never close or split it.
func TestRecordingSurvivesAreaChangesAndNilFrames(t *testing.T) {
	c := recordingCore(t)
	path, err := c.StartRecording()
	if err != nil {
		t.Fatal(err)
	}
	c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{0, 0}})
	c.forwardLocalState(nil)
	c.forwardLocalState(nil)
	c.forwardLocalState(&protocol.State{AreaID: "b", Position: []float64{0, 0}})
	c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{5, 0}})
	if !c.Recording() {
		t.Fatal("a nil frame or an area change stopped the recording")
	}
	if _, n, _ := c.StopRecording(); n != 3 {
		t.Fatalf("wrote %d, want 3", n)
	}
	_, states := readReplayLines(t, path)
	if states[0].AreaID != "a" || states[1].AreaID != "b" || states[2].AreaID != "a" {
		t.Fatalf("areas not recorded in order: %+v", states)
	}
}

// TestStopWithNothingWrittenLeavesNoFile: armed and quit before gameplay.
func TestStopWithNothingWrittenLeavesNoFile(t *testing.T) {
	c := recordingCore(t)
	path, err := c.StartRecording()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.StartRecording(); err == nil {
		t.Fatal("a second StartRecording while recording must be refused")
	}
	gotPath, n, err := c.StopRecording()
	if gotPath != "" || n != 0 || err != nil {
		t.Fatalf("StopRecording = (%q, %d, %v), want (\"\", 0, nil)", gotPath, n, err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("a file was created for an empty recording: %v", err)
	}
	if entries, _ := os.ReadDir(c.ReplayDir); len(entries) != 0 {
		t.Fatalf("replay folder not empty: %v", entries)
	}
	if c.tapArmed != 0 {
		t.Fatal("the tap stayed armed after the last consumer stopped")
	}
}

// TestRingKeepsOnlyTheLastSpan: the ring holds the newest N seconds by the
// samples' own timestamps, oldest first, and is off when nothing needs it.
func TestRingKeepsOnlyTheLastSpan(t *testing.T) {
	c := recordingCore(t)
	c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{0, 0}})
	if c.ring.snapshot() != nil {
		t.Fatal("ring collected a sample while off")
	}
	c.SetRingSpan(100 * time.Millisecond)
	for i := 0; i < 30; i++ {
		c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{float64(i), 0}})
		time.Sleep(5 * time.Millisecond)
	}
	got := c.ring.snapshot()
	if len(got) == 0 || len(got) >= 30 {
		t.Fatalf("ring holds %d of 30 samples; want fewer than all (100ms of a 150ms feed)", len(got))
	}
	newest, oldest := got[len(got)-1], got[0]
	if newest.Position[0] != 29 {
		t.Fatalf("ring does not end at the newest sample: %+v", newest)
	}
	if span := newest.Timestamp - oldest.Timestamp; span > 100 {
		t.Fatalf("ring spans %dms, want <= 100", span)
	}
	for i := 1; i < len(got); i++ {
		if got[i].Timestamp < got[i-1].Timestamp {
			t.Fatal("ring is not oldest-first")
		}
	}
	c.SetRingSpan(0)
	if c.ring.snapshot() != nil || c.tapArmed != 0 {
		t.Fatal("ring not cleared and disarmed at span 0")
	}
}

// TestStartRecordingNeedsAFolder: nothing is ever written beside the exe by
// accident.
func TestStartRecordingNeedsAFolder(t *testing.T) {
	c := New()
	if _, err := c.StartRecording(); err == nil {
		t.Fatal("StartRecording with no ReplayDir must fail")
	}
}

// TestSaveLastWritesTheRingAsAReplay: after 300ms of play with a 100ms span,
// the saved file spans at most 100ms, ends at the newest sample, is numbered
// from 1, loads as a replay, and a manual recording running at the same time
// is untouched by it.
func TestSaveLastWritesTheRingAsAReplay(t *testing.T) {
	c := recordingCore(t)
	c.SaveLastSpan = 100 * time.Millisecond
	if _, _, err := c.SaveLast(); err == nil {
		t.Fatal("SaveLast with nothing in the ring must say so")
	}
	c.armRing()
	recPath, err := c.StartRecording()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 30; i++ {
		c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{float64(i), 0}, Anim: "run"})
		time.Sleep(10 * time.Millisecond)
	}
	path, n, err := c.SaveLast()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(filepath.Base(path), "last-") || n == 0 || n >= 30 {
		t.Fatalf("SaveLast wrote %d samples to %s; want a 100ms slice of a 300ms feed", n, path)
	}
	hdr, states := readReplayLines(t, path)
	if hdr.Game != "emerald" || hdr.Recorded == "" || len(states) != n {
		t.Fatalf("saved file header %+v / %d states", hdr, len(states))
	}
	if states[len(states)-1].Position[0] != 29 {
		t.Fatalf("saved file does not end at the newest sample: %+v", states[len(states)-1])
	}
	if span := states[len(states)-1].Timestamp - states[0].Timestamp; span > 100 {
		t.Fatalf("saved file spans %dms, want <= 100", span)
	}
	for i, st := range states {
		if st.Seq != uint64(i+1) {
			t.Fatalf("saved file not renumbered from 1: %d at %d", st.Seq, i)
		}
	}
	// Through loadReplay, the same door StartReplays uses, so the gzip the
	// recorder now writes is exercised end to end rather than assumed.
	if _, err := loadReplay(path); err != nil {
		t.Fatalf("the saved file does not load as a replay: %v", err)
	}
	if _, m, _ := c.StopRecording(); m != 30 {
		t.Fatalf("the manual recording alongside wrote %d, want 30 (SaveLast must not touch it)", m)
	}
	if _, err := os.Stat(recPath); err != nil {
		t.Fatalf("manual recording file missing: %v", err)
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// TestARecordingIsGzippedAndTrimmedAndStillLoads: the two size measures that
// shipped on 2026-09-03 (scaling.md, "What a recording costs on disk"), pinned
// by behaviour rather than by a byte count.
//
// Both are LOSSLESS as far as anything visible goes -- the file still parses,
// still carries every sample, and the positions still round-trip to what was
// recorded once the deliberate precision is applied. What must never regress is
// the third property: the samples the recorder writes must not be the same
// objects the ring and the chasers hold, or trimming a file would change what a
// live ghost renders.
func TestARecordingIsGzippedAndTrimmedAndStillLoads(t *testing.T) {
	c := recordingCore(t)
	path, err := c.StartRecording()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(path, ".ndjson.gz") {
		t.Fatalf("recording path %q, want a .ndjson.gz -- gzip is the shipped default", path)
	}

	// A position with a float64 tail no player could ever see, and extras of
	// every JSON shape the rounder has to walk.
	live := &protocol.State{
		AreaID:      "a",
		Position:    []float64{-492.6911072143106, 67.14999904213690, 0},
		Orientation: []byte(`[0,1.6743471622467037,0]`),
		Anim:        "run",
		Extras: map[string]any{
			"h_speed": 550.0000000000016,
			"colour":  []any{1.0, 0.88794326, 0.26041667},
			"vfx":     "hw:0,dl:4",
			"nested":  map[string]any{"t": 0.1234567},
		},
	}
	c.forwardLocalState(live)
	if _, n, err := c.StopRecording(); err != nil || n != 1 {
		t.Fatalf("StopRecording = %d, %v, want 1 sample", n, err)
	}

	// THE FILE IS REALLY GZIP, not merely named .gz: read it the way every
	// loader in the project does.
	clip, err := loadReplay(path)
	if err != nil {
		t.Fatalf("the recording does not load: %v", err)
	}
	if len(clip.samples) != 1 {
		t.Fatalf("clip has %d samples, want 1", len(clip.samples))
	}
	got := clip.samples[0]
	if got.Position[0] != -492.691 || got.Position[1] != 67.15 {
		t.Errorf("position %v, want the 3-decimal form of what was recorded", got.Position)
	}
	if h := got.Extras["h_speed"]; h != 550.0 {
		t.Errorf("extras h_speed %v, want 550 -- the float64 tail is noise, not information", h)
	}
	if s := got.Extras["vfx"]; s != "hw:0,dl:4" {
		t.Errorf("extras vfx %v: rounding must leave strings alone", s)
	}
	if n, ok := got.Extras["nested"].(map[string]any); !ok || n["t"] != 0.123 {
		t.Errorf("extras nested %v, want a rounded value inside the map too", got.Extras["nested"])
	}
	if string(got.Orientation) != "[0,1.674347,0]" {
		t.Errorf("orientation %s, want six decimals", got.Orientation)
	}

	// The live state the adapter handed in is untouched -- the recorder copies.
	if live.Position[0] != -492.6911072143106 || live.Extras["h_speed"] != 550.0000000000016 {
		t.Fatalf("the recorder rounded the caller's own state: %v %v -- the ring and the chasers "+
			"share it, so this would change what a live ghost renders", live.Position, live.Extras)
	}
}

// TestRecordingCanStillBeWrittenPlain: the escape hatch, because a recording is
// a debugging artefact as well as a player-facing one.
func TestRecordingCanStillBeWrittenPlain(t *testing.T) {
	c := recordingCore(t)
	c.ReplayGzip = false
	path, err := c.StartRecording()
	if err != nil {
		t.Fatal(err)
	}
	if strings.HasSuffix(path, ".gz") {
		t.Fatalf("path %q with replay.gzip off", path)
	}
	c.forwardLocalState(&protocol.State{AreaID: "a", Position: []float64{1, 2}})
	if _, n, err := c.StopRecording(); err != nil || n != 1 {
		t.Fatalf("StopRecording = %d, %v", n, err)
	}
	if _, err := loadReplay(path); err != nil {
		t.Fatalf("the plain recording does not load: %v", err)
	}
}
