package core

// The replay input stream (ADR 0057): a clip's track reaches an adapter that
// asked, ahead of the frames, on the render clock, through every seam.

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// trackBytes builds an input track file: the header, then the edges.
func trackBytes(hdr map[string]any, edges []inputEdgeLine) []byte {
	var b bytes.Buffer
	h := map[string]any{"meshghost_inputs": 1, "labels": []string{"jump", "attack"}, "axes": []string{"x"}, "source": "test"}
	for k, v := range hdr {
		h[k] = v
	}
	line, _ := json.Marshal(h)
	b.Write(line)
	b.WriteByte('\n')
	for _, e := range edges {
		line, _ := json.Marshal(e)
		b.Write(line)
		b.WriteByte('\n')
	}
	return b.Bytes()
}

// edgesAt is one edge per stamp, f = the 1-based index (so a test can name an
// edge by f), m alternating so no two neighbours are identical.
func edgesAt(ts ...int64) []inputEdgeLine {
	out := make([]inputEdgeLine, len(ts))
	for i, t := range ts {
		out[i] = inputEdgeLine{Ts: t, F: uint64(i + 1), T: int64(i+1) * 16, M: uint32(i % 2)}
	}
	return out
}

// sampleStamps are the stamps walkStates(n, stepMs) gives its samples.
func sampleStamps(n int, stepMs int64) []int64 {
	out := make([]int64, n)
	for i := range out {
		out[i] = 1_000_000 + int64(i)*stepMs
	}
	return out
}

func writeInputs(t *testing.T, c *Core, name string, data []byte) string {
	t.Helper()
	dir := c.inputsDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// inputReplayCore is replayCore with an adapter that asked for input tracks.
func inputReplayCore(t *testing.T) (*Core, *fakeAdapter) {
	t.Helper()
	c, _, fa := startLocalPeerCoreHello(t, func(c *Core) {
		c.ReplayDir = filepath.Join(t.TempDir(), "replay")
		c.ReplaySeek = 1 * time.Second
	}, func(fa *fakeAdapter) { fa.helloInputTracks("emerald") })
	return c, fa
}

// drainInputs empties the input channel and returns what was for id, in order.
func drainInputs(fa *fakeAdapter, id string) []receivedInput {
	var out []receivedInput
	for {
		select {
		case got := <-fa.inputs:
			if got.msg.PlayerID == id {
				out = append(out, got)
			}
		default:
			return out
		}
	}
}

// startedAtOf reads the player's current lap base.
func startedAtOf(t *testing.T, c *Core, id string) int64 {
	t.Helper()
	c.replayMu.Lock()
	p := c.replays[id]
	c.replayMu.Unlock()
	if p == nil {
		t.Fatalf("no player %s", id)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.startedAt
}

// awaitBridgeDrained is waitAdapterDrained on whichever adapter is attached:
// sendToAdapter is asynchronous, so a line the core has sent is not yet a
// line the fake adapter has received.
func awaitBridgeDrained(t *testing.T, c *Core) {
	t.Helper()
	c.mu.Lock()
	nd := c.attachedAdapter
	c.mu.Unlock()
	if nd != nil {
		waitAdapterDrained(t, c, nd)
	}
}

// flatEdges is every edge of every message, in order.
func flatEdges(in []receivedInput) []bridge.RemoteInputEdge {
	var out []bridge.RemoteInputEdge
	for _, r := range in {
		out = append(out, r.msg.Edges...)
	}
	return out
}

// awaitFinished pumps until the clip's last sample rendered and the ghost left.
func awaitFinished(t *testing.T, fa *fakeAdapter, id string, lastX float64) {
	t.Helper()
	pumpUntil(t, fa, func() bool { return renderX(fa, id) == lastX }, "the replay to reach its last sample")
	pumpUntil(t, fa, func() bool { return drainDespawns(fa, id) > 0 }, "the finished replay to despawn")
}

// TestReplayStreamsItsTrackOnTheRenderClock: a clip with a track streams every
// edge, the first line declares the tables with a reset, each edge's `at` is
// exactly the due time its sample was fed on, and every edge arrives BEFORE
// the render it is due on -- ahead by the window, not just in time.
func TestReplayStreamsItsTrackOnTheRenderClock(t *testing.T) {
	c, fa := inputReplayCore(t)
	writeActive(t, c, "pb.ndjson", clipBytes(map[string]any{"recording_id": "rec-1"}, walkStates(11, 100)))
	stamps := sampleStamps(11, 100)[2:] // edges on samples 2..10
	writeInputs(t, c, "in-1.ndjson", trackBytes(map[string]any{"recording_id": "rec-1"}, edgesAt(stamps...)))
	if n := c.StartReplays(); n != 1 {
		t.Fatalf("StartReplays loaded %d, want 1", n)
	}
	const id = "replay:pb.ndjson"
	awaitFinished(t, fa, id, 10)
	awaitBridgeDrained(t, c)

	got := drainInputs(fa, id)
	if len(got) == 0 {
		t.Fatal("no remote_input arrived for a clip with a track and an adapter that asked")
	}
	first := got[0].msg
	if !first.Reset || len(first.Labels) != 2 || first.Labels[0] != "jump" || first.Source != "test" || len(first.Axes) != 1 {
		t.Fatalf("the first line must carry reset and the header tables, got %+v", first)
	}
	for _, r := range got[1:] {
		if r.msg.Reset || r.msg.Labels != nil {
			t.Fatalf("a later line re-declared: %+v", r.msg)
		}
	}
	edges := flatEdges(got)
	if len(edges) != len(stamps) {
		t.Fatalf("%d edges arrived, want %d", len(edges), len(stamps))
	}
	startedAt := startedAtOf(t, c, id)
	ahead := false
	for i, e := range edges {
		if e.F != uint64(i+1) {
			t.Fatalf("edge %d has f=%d, want %d: reordered or lost", i, e.F, i+1)
		}
		// Sample k's stamp is t0 + k*100; edge i sits on sample i+2.
		want := startedAt + int64(i+2)*100
		if e.At != want {
			t.Fatalf("edge f=%d at=%d, want %d (startedAt %d): not the sample's own due time", e.F, e.At, want, startedAt)
		}
	}
	for _, r := range got {
		for _, e := range r.msg.Edges {
			if e.At < r.renderTs {
				t.Fatalf("edge f=%d (at %d) arrived after a render at %d -- late, not ahead", e.F, e.At, r.renderTs)
			}
			if e.At-r.renderTs >= 200 {
				ahead = true
			}
		}
	}
	if !ahead {
		t.Fatal("no edge arrived more than 200ms ahead of the renders: the window is not being sent ahead")
	}
}

// TestReplayTrackIsNeverSentToAnAdapterThatDidNotAsk: the same files, a bare
// hello -- nothing streams, and the inputs folder is never even scanned.
func TestReplayTrackIsNeverSentToAnAdapterThatDidNotAsk(t *testing.T) {
	c, fa := replayCore(t)
	writeActive(t, c, "pb.ndjson", clipBytes(map[string]any{"recording_id": "rec-1"}, walkStates(11, 100)))
	writeInputs(t, c, "in-1.ndjson", trackBytes(map[string]any{"recording_id": "rec-1"}, edgesAt(sampleStamps(11, 100)...)))
	c.StartReplays()
	const id = "replay:pb.ndjson"
	awaitFinished(t, fa, id, 10)
	awaitBridgeDrained(t, c)
	if got := drainInputs(fa, id); len(got) != 0 {
		t.Fatalf("%d remote_input line(s) reached an adapter that never asked", len(got))
	}
	if n := atomic.LoadUint32(&c.inputTrackScans); n != 0 {
		t.Fatalf("replay/inputs was scanned %d time(s) for an adapter that cannot use a track", n)
	}
}

// inputPlayingCore is playingCore with a track on the clip (an edge on every
// sample, f = 1-based sample index) and an adapter that asked.
func inputPlayingCore(t *testing.T, hdr map[string]any) (*Core, *fakeAdapter, string) {
	t.Helper()
	c, fa := inputReplayCore(t)
	h := map[string]any{"recording_id": "rec-s"}
	for k, v := range hdr {
		h[k] = v
	}
	writeActive(t, c, "seek.ndjson", clipBytes(h, walkStates(40, 100)))
	writeInputs(t, c, "in-s.ndjson", trackBytes(map[string]any{"recording_id": "rec-s"}, edgesAt(sampleStamps(40, 100)...)))
	c.StartReplays()
	const id = "replay:seek.ndjson"
	pumpUntil(t, fa, func() bool { return renderX(fa, id) >= 5 }, "the clip to reach x=5")
	drainDespawns(fa, id)
	drainInputs(fa, id)
	return c, fa, id
}

// firstAfterSeam pumps until a remote_input arrives that was received after
// the n-th despawn, and returns it.
func firstAfterSeam(t *testing.T, fa *fakeAdapter, id string, n int) receivedInput {
	t.Helper()
	var got receivedInput
	pumpUntil(t, fa, func() bool {
		for _, r := range drainInputs(fa, id) {
			if r.despawns >= n {
				got = r
				return true
			}
		}
		return false
	}, "a remote_input after the seam")
	return got
}

// TestReplaySeekResetsTheTrack: restart and rewind each seam the ghost, and
// the first line after the seam carries a reset with the tables and edges
// from the new position -- never a stale edge from before the seek.
func TestReplaySeekResetsTheTrack(t *testing.T) {
	c, fa, id := inputPlayingCore(t, nil)
	if _, err := c.ReplayControl(ReplayRestart, 0); err != nil {
		t.Fatal(err)
	}
	r := firstAfterSeam(t, fa, id, 1)
	if !r.msg.Reset || len(r.msg.Labels) != 2 {
		t.Fatalf("the first line after the restart seam must be a reset with the tables, got %+v", r.msg)
	}
	if len(r.msg.Edges) == 0 || r.msg.Edges[0].F > 3 {
		t.Fatalf("after a restart the stream resumes from the top, got first edge %+v", r.msg.Edges)
	}
	startedAt := startedAtOf(t, c, id)
	for _, e := range r.msg.Edges {
		if e.At < startedAt {
			t.Fatalf("edge f=%d at=%d is due before the new lap began at %d", e.F, e.At, startedAt)
		}
	}

	pumpUntil(t, fa, func() bool { return renderX(fa, id) >= 12 }, "x=12")
	drainInputs(fa, id)
	if _, err := c.ReplayControl(ReplayRewind, 1); err != nil {
		t.Fatal(err)
	}
	r = firstAfterSeam(t, fa, id, 2)
	if !r.msg.Reset {
		t.Fatalf("the first line after the rewind seam must be a reset, got %+v", r.msg)
	}
	if len(r.msg.Edges) == 0 || r.msg.Edges[0].F > 8 {
		t.Fatalf("after a 1s rewind from x>=12 the stream resumes well before sample 12, got first edge %+v", r.msg.Edges)
	}
}

// TestReplayLoopResetsTheTrackEveryLap: a looping clip seams every lap, and
// every lap's first line is a reset.
func TestReplayLoopResetsTheTrackEveryLap(t *testing.T) {
	c, fa := inputReplayCore(t)
	writeActive(t, c, "loop.ndjson", clipBytes(map[string]any{"recording_id": "rec-l", "loop": true}, walkStates(5, 100)))
	writeInputs(t, c, "in-l.ndjson", trackBytes(map[string]any{"recording_id": "rec-l"}, edgesAt(sampleStamps(5, 100)...)))
	c.StartReplays()
	const id = "replay:loop.ndjson"
	var all []receivedInput
	laps := 0
	pumpUntil(t, fa, func() bool {
		all = append(all, drainInputs(fa, id)...)
		laps += drainDespawns(fa, id)
		return laps >= 3
	}, "three laps")
	c.StopReplays()
	seen := map[int]bool{}
	resets := 0
	for _, r := range all {
		if r.msg.Reset {
			resets++
		}
		if !seen[r.despawns] {
			seen[r.despawns] = true
			if !r.msg.Reset {
				t.Fatalf("the first line after despawn #%d is not a reset: %+v", r.despawns, r.msg)
			}
		}
	}
	if len(seen) < 3 {
		t.Fatalf("lines were seen after only %d distinct seams, want at least 3 (resets %d)", len(seen), resets)
	}
}

// TestReplayTrackScalesWithSpeed: at 4x, edges 100ms apart in the file are
// 25ms apart in `at`.
func TestReplayTrackScalesWithSpeed(t *testing.T) {
	c, fa := inputReplayCore(t)
	writeActive(t, c, "fast.ndjson", clipBytes(map[string]any{"recording_id": "rec-f", "speed": 4.0}, walkStates(21, 100)))
	writeInputs(t, c, "in-f.ndjson", trackBytes(map[string]any{"recording_id": "rec-f"}, edgesAt(sampleStamps(21, 100)...)))
	c.StartReplays()
	const id = "replay:fast.ndjson"
	awaitFinished(t, fa, id, 20)
	awaitBridgeDrained(t, c)
	edges := flatEdges(drainInputs(fa, id))
	if len(edges) != 21 {
		t.Fatalf("%d edges, want 21", len(edges))
	}
	for i := 1; i < len(edges); i++ {
		if d := edges[i].At - edges[i-1].At; d != 25 {
			t.Fatalf("edges %d,%d are %dms apart in at, want 25 at 4x", i-1, i, d)
		}
	}
}

// TestReplayTrackFollowsSkipGapsAndTrim: an edge before trim_start is not
// sent, one inside a gap skip_gaps cut is not sent, one after the cut is
// shifted by exactly what the samples were, and one past the last sample is
// not sent.
func TestReplayTrackFollowsSkipGapsAndTrim(t *testing.T) {
	c, fa := inputReplayCore(t)
	var states []protocol.State
	for i := 0; i < 16; i++ {
		ts := int64(1_000_000 + i*100)
		if i >= 10 {
			ts = int64(1_003_900 + (i-10)*100) // a 3s hole after sample 9
		}
		states = append(states, protocol.State{Seq: uint64(i + 1), Timestamp: ts, AreaID: "a", Position: []float64{float64(i), 0}, Anim: "run"})
	}
	writeActive(t, c, "cut.ndjson", clipBytes(map[string]any{"recording_id": "rec-c", "skip_gaps": "1s", "trim_start": "200ms"}, states))
	// f=1 before the trim, f=2 on the first kept sample, f=3 on the sample
	// before the hole, f=4 inside the hole, f=5 on the first sample after it,
	// f=6 later, f=7 past the end.
	writeInputs(t, c, "in-c.ndjson", trackBytes(map[string]any{"recording_id": "rec-c"},
		edgesAt(1_000_000, 1_000_200, 1_000_900, 1_002_000, 1_003_900, 1_004_300, 1_010_000)))
	c.StartReplays()
	const id = "replay:cut.ndjson"
	awaitFinished(t, fa, id, 15)
	awaitBridgeDrained(t, c)
	edges := flatEdges(drainInputs(fa, id))
	// The seam at the hole re-sends what was already out ahead; count by f.
	byF := map[uint64]int64{}
	for _, e := range edges {
		byF[e.F] = e.At
	}
	for _, f := range []uint64{1, 4, 7} {
		if _, ok := byF[f]; ok {
			t.Fatalf("edge f=%d was sent; it lies outside the clip (before trim, inside the cut, or past the end)", f)
		}
	}
	startedAt := startedAtOf(t, c, id)
	want := map[uint64]int64{2: 0, 3: 700, 5: 701, 6: 1101}
	for f, off := range want {
		at, ok := byF[f]
		if !ok {
			t.Fatalf("edge f=%d never arrived", f)
		}
		if at != startedAt+off {
			t.Fatalf("edge f=%d at %d, want startedAt+%d = %d: the trim/skip_gaps shift was not applied", f, at, off, startedAt+off)
		}
	}
}

// TestReplayTrackWindowIsBoundedPerLine: a burst of 600 edges at one instant
// goes out in lines of at most 64, nothing lost, nothing reordered.
func TestReplayTrackWindowIsBoundedPerLine(t *testing.T) {
	c, fa := inputReplayCore(t)
	writeActive(t, c, "burst.ndjson", clipBytes(map[string]any{"recording_id": "rec-b"}, walkStates(11, 100)))
	stamps := make([]int64, 600)
	for i := range stamps {
		stamps[i] = 1_000_050
	}
	writeInputs(t, c, "in-b.ndjson", trackBytes(map[string]any{"recording_id": "rec-b"}, edgesAt(stamps...)))
	c.StartReplays()
	const id = "replay:burst.ndjson"
	awaitFinished(t, fa, id, 10)
	awaitBridgeDrained(t, c)
	got := drainInputs(fa, id)
	for _, r := range got {
		if len(r.msg.Edges) > bridge.MaxInputEdgesPerBatch {
			t.Fatalf("a line carried %d edges, over %d", len(r.msg.Edges), bridge.MaxInputEdgesPerBatch)
		}
	}
	edges := flatEdges(got)
	if len(edges) != 600 {
		t.Fatalf("%d edges arrived, want 600", len(edges))
	}
	for i, e := range edges {
		if e.F != uint64(i+1) {
			t.Fatalf("edge %d has f=%d: reordered or lost across lines", i, e.F)
		}
	}
}

// TestInputTrackLookupNewestWinsAndMissingIsLogged: two tracks claim one
// recording_id and the newer file's edges stream; a clip with no track says so
// in the log and plays anyway.
func TestInputTrackLookupNewestWinsAndMissingIsLogged(t *testing.T) {
	var logged lockedBuffer
	prevOut := log.Writer()
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(prevOut) })

	c, fa := inputReplayCore(t)
	writeActive(t, c, "a.ndjson", clipBytes(map[string]any{"recording_id": "rec-1"}, walkStates(6, 100)))
	writeActive(t, c, "b.ndjson", clipBytes(map[string]any{"recording_id": "rec-none"}, walkStates(6, 100)))
	old := edgesAt(sampleStamps(6, 100)...)
	for i := range old {
		old[i].F += 100
		old[i].T += 1600
	}
	oldPath := writeInputs(t, c, "in-old.ndjson", trackBytes(map[string]any{"recording_id": "rec-1"}, old))
	past := time.Now().Add(-time.Hour)
	if err := os.Chtimes(oldPath, past, past); err != nil {
		t.Fatal(err)
	}
	writeInputs(t, c, "in-new.ndjson", trackBytes(map[string]any{"recording_id": "rec-1"}, edgesAt(sampleStamps(6, 100)...)))
	if n := c.StartReplays(); n != 2 {
		t.Fatalf("loaded %d, want 2", n)
	}
	// Both clips end together; drainDespawns discards the other id's despawn,
	// so count them jointly rather than one clip at a time.
	gone := 0
	pumpUntil(t, fa, func() bool {
		for {
			select {
			case <-fa.despawns:
				gone++
			default:
				return gone >= 2
			}
		}
	}, "both replays to finish and despawn")
	awaitBridgeDrained(t, c)
	edges := flatEdges(drainInputs(fa, "replay:a.ndjson"))
	if len(edges) == 0 {
		t.Fatal("no edges for the clip with two candidate tracks")
	}
	for _, e := range edges {
		if e.F > 100 {
			t.Fatalf("edge f=%d is from the OLDER track; the newest file must win", e.F)
		}
	}
	if got := drainInputs(fa, "replay:b.ndjson"); len(got) != 0 {
		t.Fatalf("the clip with no track received %d line(s)", len(got))
	}
	logged.mu.Lock()
	text := logged.buf.String()
	logged.mu.Unlock()
	if !strings.Contains(text, `no input track for recording_id "rec-none"`) {
		t.Fatalf("the missing track was not logged; log:\n%s", text)
	}
}

// TestZipCarriesItsOwnTrack: a track inside the clip's zip is matched by
// recording_id and streams; a track matching no clip is logged and ignored;
// a track over the archive budget is dropped and the clip still plays.
func TestZipCarriesItsOwnTrack(t *testing.T) {
	var logged lockedBuffer
	prevOut := log.Writer()
	log.SetOutput(&logged)
	t.Cleanup(func() { log.SetOutput(prevOut) })

	c, fa := inputReplayCore(t)
	dir := filepath.Join(c.ReplayDir, "active")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	stamps := sampleStamps(6, 100)
	zipWith(t, filepath.Join(dir, "pack.zip"), map[string][]byte{
		"a.ndjson":           clipBytes(map[string]any{"recording_id": "rec-a"}, walkStates(6, 100)),
		"inputs/in-a.ndjson": trackBytes(map[string]any{"recording_id": "rec-a"}, edgesAt(stamps...)),
		"stray.ndjson":       trackBytes(map[string]any{"recording_id": "rec-zzz"}, edgesAt(stamps...)),
	}, []string{"stray.ndjson", "a.ndjson", "inputs/in-a.ndjson"})
	if n := c.StartReplays(); n != 1 {
		t.Fatalf("loaded %d, want 1 (the zip's one clip; its tracks are not clips)", n)
	}
	const id = "replay:pack.zip/a.ndjson"
	awaitFinished(t, fa, id, 5)
	awaitBridgeDrained(t, c)
	if edges := flatEdges(drainInputs(fa, id)); len(edges) != 6 {
		t.Fatalf("%d edges from the zip's own track, want 6", len(edges))
	}
	logged.mu.Lock()
	text := logged.buf.String()
	logged.mu.Unlock()
	if !strings.Contains(text, `matches no clip in the archive (recording_id "rec-zzz")`) {
		t.Fatalf("the unmatched track was not logged; log:\n%s", text)
	}

	// Over budget: the track is refused, the clip is not.
	prev := replayMaxTrackEdgesPerArchive
	replayMaxTrackEdgesPerArchive = 3
	t.Cleanup(func() { replayMaxTrackEdgesPerArchive = prev })
	c.StopReplays()
	os.Remove(filepath.Join(dir, "pack.zip"))
	zipWith(t, filepath.Join(dir, "big.zip"), map[string][]byte{
		"b.ndjson":  clipBytes(map[string]any{"recording_id": "rec-b"}, walkStates(6, 100)),
		"in.ndjson": trackBytes(map[string]any{"recording_id": "rec-b"}, edgesAt(stamps...)),
	}, []string{"b.ndjson", "in.ndjson"})
	if n := c.StartReplays(); n != 1 {
		t.Fatalf("loaded %d, want 1", n)
	}
	const id2 = "replay:big.zip/b.ndjson"
	awaitFinished(t, fa, id2, 5)
	awaitBridgeDrained(t, c)
	if got := drainInputs(fa, id2); len(got) != 0 {
		t.Fatalf("a track over the archive budget still streamed %d line(s)", len(got))
	}
}

// TestReplayTrackOverTheCapIsTruncatedNotRefused: attachTrack keeps the first
// replayMaxTrackEdges and the clip keeps its track.
func TestReplayTrackOverTheCapIsTruncatedNotRefused(t *testing.T) {
	clip := &replayClip{file: "cap", samples: walkStates(2, 10_000_000), forcedSeam: map[int]bool{}}
	clip.applyTrim()
	clip.t0 = clip.samples[0].Timestamp
	tr := &inputTrack{file: "big", edges: make([]inputEdgeLine, replayMaxTrackEdges+1)}
	for i := range tr.edges {
		tr.edges[i] = inputEdgeLine{Ts: 1_000_000 + int64(i), F: uint64(i), T: int64(i), M: uint32(i & 1)}
	}
	clip.attachTrack(tr)
	if clip.track == nil {
		t.Fatal("the clip lost its track entirely")
	}
	if n := len(clip.track.edges); n != replayMaxTrackEdges {
		t.Fatalf("%d edges kept, want exactly %d", n, replayMaxTrackEdges)
	}
}

// TestReplayHelloFlagResetsOnDetach: the flag the hello set is cleared when
// the adapter goes, so the next adapter's bare hello means what it says.
func TestReplayHelloFlagResetsOnDetach(t *testing.T) {
	c, _, fa := startLocalPeerCoreHello(t, nil, func(fa *fakeAdapter) { fa.helloInputTracks("emerald") })
	c.mu.Lock()
	on := c.adapterWantsInputTracks
	c.mu.Unlock()
	if !on {
		t.Fatal("the hello asked for input tracks and the core did not record it")
	}
	fa.conn.Close()
	deadline := time.Now().Add(testTimeout)
	for {
		c.mu.Lock()
		on = c.adapterWantsInputTracks
		c.mu.Unlock()
		if !on {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the flag survived the adapter's departure")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestReplayRelaunchAfterFinishStreamsAgain: a restart pressed after a
// non-looping clip has FINISHED relaunches a fresh player (seekReplays), and
// that player streams the track again -- a reset first, edges due from the
// new lap's start, and renders that actually reach every edge's `at`.
// Written 2026-09-08 after a relaunched replay's ghost panel stayed empty in
// the game while the first pass had worked.
func TestReplayRelaunchAfterFinishStreamsAgain(t *testing.T) {
	c, fa := inputReplayCore(t)
	writeActive(t, c, "again.ndjson", clipBytes(map[string]any{"recording_id": "rec-a"}, walkStates(11, 100)))
	writeInputs(t, c, "in-a.ndjson", trackBytes(map[string]any{"recording_id": "rec-a"}, edgesAt(sampleStamps(11, 100)...)))
	c.StartReplays()
	const id = "replay:again.ndjson"
	awaitFinished(t, fa, id, 10)
	awaitBridgeDrained(t, c)
	drainInputs(fa, id)
	if _, err := c.ReplayControl(ReplayRestart, 0); err != nil {
		t.Fatal(err)
	}
	awaitFinished(t, fa, id, 10)
	awaitBridgeDrained(t, c)
	got := drainInputs(fa, id)
	if len(got) == 0 {
		t.Fatal("the relaunched player streamed nothing")
	}
	if !got[0].msg.Reset || len(got[0].msg.Labels) == 0 {
		t.Fatalf("the relaunch's first line must be a reset with the tables, got %+v", got[0].msg)
	}
	edges := flatEdges(got)
	if len(edges) != 11 {
		t.Fatalf("%d edges on the relaunch, want 11", len(edges))
	}
	fa.mu.Lock()
	lastRender := fa.lastRenderTs[id]
	fa.mu.Unlock()
	for _, e := range edges {
		if e.At > lastRender {
			t.Fatalf("edge f=%d at=%d was never reached by a render (newest render ts %d): it could never apply", e.F, e.At, lastRender)
		}
	}
}
