package core

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// clipBytes builds a replay file: the header, then samples `stepMs` apart
// walking x = 0..n-1 in area "a" (or as given).
func clipBytes(hdr map[string]any, states []protocol.State) []byte {
	var b bytes.Buffer
	h := map[string]any{"meshghost_replay": 1}
	for k, v := range hdr {
		h[k] = v
	}
	line, _ := json.Marshal(h)
	b.Write(line)
	b.WriteByte('\n')
	for _, st := range states {
		line, _ := json.Marshal(st)
		b.Write(line)
		b.WriteByte('\n')
	}
	return b.Bytes()
}

func walkStates(n int, stepMs int64) []protocol.State {
	out := make([]protocol.State, n)
	for i := range out {
		out[i] = protocol.State{Seq: uint64(i + 1), Timestamp: 1_000_000 + int64(i)*stepMs, AreaID: "a", Position: []float64{float64(i), 0}, Anim: "run"}
	}
	return out
}

func writeActive(t *testing.T, c *Core, name string, data []byte) string {
	t.Helper()
	dir := filepath.Join(c.ReplayDir, "active")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// replayCore is startLocalPeerCore plus a replay folder.
func replayCore(t *testing.T) (*Core, *fakeAdapter) {
	t.Helper()
	c, _, fa := startLocalPeerCore(t)
	c.ReplayDir = filepath.Join(t.TempDir(), "replay")
	return c, fa
}

// TestReplayRendersItsClipAtSpeedWithItsName: a file in replay/active plays as
// a cosmetic ghost named from its header, starts at the first in-game frame,
// walks the recorded positions, and finishes in the recorded time over speed.
func TestReplayRendersItsClipAtSpeedWithItsName(t *testing.T) {
	c, fa := replayCore(t)
	// 2s of recording at 4x should finish in ~0.5s; at 1x it must not.
	writeActive(t, c, "pb.ndjson", clipBytes(map[string]any{"name": "PB", "color": "#FF8800", "speed": 4.0, "game": "emerald"}, walkStates(21, 100)))
	if n := c.StartReplays(); n != 1 {
		t.Fatalf("StartReplays loaded %d, want 1", n)
	}
	const id = "replay:pb.ndjson"
	t0 := time.Now()
	var last bridge.RenderRemote
	pumpUntil(t, fa, func() bool {
		m, ok := fa.renderMsgOf(id)
		if ok {
			last = m
		}
		return ok && len(m.State.Position) == 2 && m.State.Position[0] == 20
	}, "the replay to reach its last sample")
	if took := time.Since(t0); took > 1500*time.Millisecond {
		t.Fatalf("a 2s clip at 4x took %s to finish", took)
	}
	if !last.Cosmetic || last.State.Anim != "run" || last.State.PlayerID != id {
		t.Fatalf("last render wrong: %+v", last)
	}
	fa.mu.Lock()
	name := fa.names[id]
	fa.mu.Unlock()
	// The name may already carry a split suffix ("PB +0.3s"): the tag is
	// the header name first, whatever follows.
	if !strings.HasPrefix(name.DisplayName, "PB") || name.Color != "#FF8800" {
		t.Fatalf("nametag %+v, want PB.../#FF8800", name)
	}
	// Not looping: it leaves when done.
	pumpUntil(t, fa, func() bool {
		select {
		case got := <-fa.despawns:
			return got == id
		default:
			return false
		}
	}, "the finished replay to despawn")
	if c.ActiveReplays() != 1 {
		t.Fatalf("ActiveReplays = %d after finishing; a finished player stays loaded until StopReplays", c.ActiveReplays())
	}
}

// TestReplayDoesNotStartBeforeTheFirstInGameFrame: loaded at attach, silent
// until the player is in the world, then the start delay counts from there.
func TestReplayDoesNotStartBeforeTheFirstInGameFrame(t *testing.T) {
	c, fa := replayCore(t)
	writeActive(t, c, "x.ndjson", clipBytes(map[string]any{"start_delay": "300ms"}, walkStates(5, 50)))
	c.StartReplays()
	time.Sleep(150 * time.Millisecond)
	if _, ok := fa.renderMsgOf("replay:x.ndjson"); ok {
		t.Fatal("the replay rendered before any in-game frame")
	}
	fa.frame(nil) // a menu frame is not an in-game frame
	time.Sleep(50 * time.Millisecond)
	if _, ok := fa.renderMsgOf("replay:x.ndjson"); ok {
		t.Fatal("a nil frame started the replay")
	}
	t0 := time.Now()
	pumpUntil(t, fa, func() bool { _, ok := fa.renderMsgOf("replay:x.ndjson"); return ok }, "the replay to start after the first in-game frame")
	if since := time.Since(t0); since < 250*time.Millisecond {
		t.Fatalf("the replay started %s after the first frame, want the 300ms start_delay honoured", since)
	}
}

// TestReplayLoopsWithOneSeamPerLap: loop=true restarts through a leave and
// rejoin, so the adapter sees exactly one despawn per lap and no glide.
func TestReplayLoopsWithOneSeamPerLap(t *testing.T) {
	c, fa := replayCore(t)
	writeActive(t, c, "loop.ndjson", clipBytes(map[string]any{"loop": true, "speed": 4.0}, walkStates(9, 100)))
	c.StartReplays()
	const id = "replay:loop.ndjson"
	despawns := 0
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) && despawns < 3 {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{0, 0}})
		time.Sleep(5 * time.Millisecond)
		select {
		case got := <-fa.despawns:
			if got == id {
				despawns++
			}
		default:
		}
	}
	if despawns < 3 {
		t.Fatalf("saw %d despawns in %v; want one per lap (>= 3 laps of a 0.2s loop)", despawns, testTimeout)
	}
	if _, ok := fa.renderMsgOf(id); !ok {
		t.Fatal("the looping replay is not rendering")
	}
	c.StopReplays()
	if c.ActiveReplays() != 0 {
		t.Fatal("StopReplays left players loaded")
	}
}

// TestReplayGapIsASeamAndAFullRunPlaysThrough: a full-run clip spanning areas
// a -> b -> a with a 2s loading gap at each transition plays end to end; the
// ghost renders only while the local area matches, and each gap is a
// despawn/respawn rather than a blend. The clock runs through the gaps:
// at 4x the whole 4.8s clip is done in ~1.2s.
func TestReplayGapIsASeamAndAFullRunPlaysThrough(t *testing.T) {
	c, fa := replayCore(t)
	var states []protocol.State
	ts := int64(5_000_000)
	add := func(area string, x float64) {
		states = append(states, protocol.State{Timestamp: ts, AreaID: area, Position: []float64{x, 0}})
		ts += 100
	}
	for i := 0; i < 4; i++ {
		add("a", float64(i))
	}
	ts += 2000
	for i := 0; i < 4; i++ {
		add("b", float64(10+i))
	}
	ts += 2000
	for i := 0; i < 4; i++ {
		add("a", float64(20+i))
	}
	writeActive(t, c, "run.ndjson", clipBytes(map[string]any{"speed": 4.0}, states))
	c.StartReplays()
	const id = "replay:run.ndjson"

	sawB, sawA2, despawns := false, false, 0
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) && !sawA2 {
		// The local player stays in area "a": area "b" must never render.
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{0, 0}})
		time.Sleep(5 * time.Millisecond)
		if m, ok := fa.renderMsgOf(id); ok {
			if m.State.AreaID == "b" {
				sawB = true
			}
			if m.State.AreaID == "a" && m.State.Position[0] >= 20 {
				sawA2 = true
			}
		}
		select {
		case got := <-fa.despawns:
			if got == id {
				despawns++
			}
		default:
		}
	}
	if sawB {
		t.Fatal("a sample from area b rendered while the player was in area a")
	}
	if !sawA2 {
		t.Fatal("the replay never came back to area a after the gaps")
	}
	if despawns < 1 {
		t.Fatalf("saw %d despawns across two 2s gaps; want at least one seam", despawns)
	}
}

// TestReplaySkipsAFileForAnotherGameAndReadsGzip: equality on the header's
// game, a gzipped file, and a future format that only warns.
func TestReplaySkipsAFileForAnotherGameAndReadsGzip(t *testing.T) {
	c, fa := replayCore(t)
	writeActive(t, c, "other.ndjson", clipBytes(map[string]any{"game": "someothergame"}, walkStates(3, 50)))
	var gz bytes.Buffer
	w := gzip.NewWriter(&gz)
	w.Write(clipBytes(map[string]any{"meshghost_replay": 99, "name": "Zip", "game": "emerald"}, walkStates(3, 50)))
	w.Close()
	writeActive(t, c, "zipped.ndjson.gz", gz.Bytes())
	writeActive(t, c, "notes.txt", []byte("not a replay"))
	if n := c.StartReplays(); n != 1 {
		t.Fatalf("StartReplays loaded %d, want 1 (the gz; the other game and the .txt skipped)", n)
	}
	pumpUntil(t, fa, func() bool { _, ok := fa.renderMsgOf("replay:zipped.ndjson.gz"); return ok }, "the gzipped replay to render")
	if _, ok := fa.renderMsgOf("replay:other.ndjson"); ok {
		t.Fatal("a replay for another game rendered")
	}
}

// TestParseReplayRefusesWhatTheWireWouldRefuse: the loader is the same door
// as the relay -- an oversized line, an invalid state, a backwards clock and a
// missing header are all refused with a line number.
func TestParseReplayRefusesWhatTheWireWouldRefuse(t *testing.T) {
	good := walkStates(3, 50)
	cases := map[string][]byte{
		"empty":            {},
		"no header":        []byte(`{"area_id":"a","position":[1,2]}` + "\n"),
		"not json":         []byte("hello\n"),
		"header only":      clipBytes(nil, nil),
		"long line":        append(clipBytes(nil, nil), []byte(`{"area_id":"`+strings.Repeat("x", protocol.MaxLineBytes)+`"}`+"\n")...),
		"bad position":     clipBytes(nil, []protocol.State{{Timestamp: 1, AreaID: "a", Position: []float64{1e300}}}),
		"backwards clock":  clipBytes(nil, []protocol.State{{Timestamp: 10, AreaID: "a", Position: []float64{0}}, {Timestamp: 5, AreaID: "a", Position: []float64{1}}}),
		"trim leaves none": clipBytes(map[string]any{"trim_start": "1h"}, good),
	}
	for name, data := range cases {
		if _, err := parseReplay(bytes.NewReader(data), name); err == nil {
			t.Errorf("%s: parsed without error", name)
		}
	}
	clip, err := parseReplay(bytes.NewReader(clipBytes(map[string]any{"name": "‮evil", "color": "red", "speed": 99, "start_delay": "-5s", "anchor": "sideways"}, good)), "sanitize")
	if err != nil {
		t.Fatal(err)
	}
	if clip.header.Name != "evil" || clip.header.Color != "" || clip.speed != replaySpeedMax || clip.startDelay != 0 || clip.header.Anchor != "launch" {
		t.Fatalf("header not sanitized: %+v speed %v delay %v", clip.header, clip.speed, clip.startDelay)
	}
}

// TestParseReplayTrimAndSkipGaps: the defaults replay a leading standstill
// and a mid-clip pause at full length; the opt-in trim_start "auto" starts at
// the first movement, skip_gaps cuts a long pause out of the clock and marks a
// seam there, trim_end drops the tail.
func TestParseReplayTrimAndSkipGaps(t *testing.T) {
	var states []protocol.State
	ts := int64(1000)
	push := func(x float64, dt int64) {
		ts += dt
		states = append(states, protocol.State{Timestamp: ts, AreaID: "a", Position: []float64{x, 0}})
	}
	push(0, 0)
	push(0, 100) // standing still for 300ms
	push(0, 100)
	push(0, 100)
	push(1, 100) // moves
	push(2, 100)
	push(3, 5000) // a 5s pause before this one
	push(4, 100)
	push(5, 100)

	def, err := parseReplay(bytes.NewReader(clipBytes(nil, states)), "def")
	if err != nil {
		t.Fatal(err)
	}
	if len(def.samples) != 9 || def.duration() != 5700*time.Millisecond {
		t.Fatalf("defaults trimmed something: %d samples, %s", len(def.samples), def.duration())
	}

	cut, err := parseReplay(bytes.NewReader(clipBytes(map[string]any{"trim_start": "auto", "skip_gaps": "2s", "trim_end": "100ms"}, states)), "cut")
	if err != nil {
		t.Fatal(err)
	}
	if cut.samples[0].Position[0] != 0 || cut.samples[1].Position[0] != 1 {
		t.Fatalf("auto trim should keep the last still sample then the first move: %v", cut.samples[:2])
	}
	if last := cut.samples[len(cut.samples)-1].Position[0]; last != 4 {
		t.Fatalf("trim_end 100ms should drop x=5, last is %v", last)
	}
	if d := cut.duration(); d > time.Second {
		t.Fatalf("skip_gaps left the 5s pause in the clock: %s", d)
	}
	seams := 0
	for range cut.forcedSeam {
		seams++
	}
	if seams != 1 {
		t.Fatalf("want exactly one forced seam at the cut, got %d", seams)
	}
}

// TestReplayCapAndPrefixNeverEscapeTheFolder: more than the cap is skipped
// with a log line, and the id is the listing name, never anything from inside.
func TestReplayCapAndPrefixNeverEscapeTheFolder(t *testing.T) {
	c, _ := replayCore(t)
	for i := 0; i < maxActiveReplays+3; i++ {
		writeActive(t, c, fmt.Sprintf("r%02d.ndjson", i), clipBytes(map[string]any{"name": "../../etc"}, walkStates(2, 50)))
	}
	if n := c.StartReplays(); n != maxActiveReplays {
		t.Fatalf("loaded %d, want the cap %d", n, maxActiveReplays)
	}
	c.replayMu.Lock()
	for id := range c.replays {
		if !strings.HasPrefix(id, "replay:r") || strings.Contains(id, "..") {
			t.Errorf("id %q is not the listing name", id)
		}
	}
	c.replayMu.Unlock()
	c.StopReplays()
}
