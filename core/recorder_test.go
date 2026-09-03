package core

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
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
	sc := bufio.NewScanner(f)
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
