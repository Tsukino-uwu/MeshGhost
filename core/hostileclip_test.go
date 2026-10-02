package core

// A hostile replay clip against whoever was given it: players send each other zips, and StartReplays loads everything
// in replay/active/ the moment the adapter attaches. There is no path traversal: zip entries are only opened into
// memory, never extracted, and the on-disk path is always filepath.Join(dir, filepath.Base(name)) from the listing.

import (
	"archive/zip"
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

// nestedExtrasLine is a sample that is small on disk and large in memory, which makes a sample count the wrong unit.
func nestedExtrasLine(t *testing.T) string {
	t.Helper()
	var v any = map[string]any{"a": 1}
	for i := 0; i < 5; i++ {
		v = map[string]any{"a": v, "b": v}
	}
	b, err := json.Marshal(map[string]any{"timestamp": 1, "extras": map[string]any{"e": v}})
	if err != nil {
		t.Fatal(err)
	}
	var st protocol.State
	if err := json.Unmarshal(b, &st); err != nil {
		t.Fatal(err)
	}
	if !protocol.ValidateState(st) {
		t.Fatalf("test premise broken: the nested sample is refused by ValidateState (%s)",
			protocol.StateRejectReason(st))
	}
	return string(b)
}

// TestAClipIsBoundedByWhatItCostsToHoldNotOnlyByItsLineCount: a budget in samples assumes every sample is as small as
// "{}", which nested extras are not, so a clip is also bounded by what it costs to hold.
func TestAClipIsBoundedByWhatItCostsToHoldNotOnlyByItsLineCount(t *testing.T) {
	line := nestedExtrasLine(t)
	one := replaySampleCost(mustParseState(t, line))
	if one < 4000 {
		t.Fatalf("test premise broken: the nested sample is estimated at only %d B", one)
	}

	// Shrunk so the refusal is reachable without a quarter-gigabyte fixture --
	// room for ten of these and no more.
	restore := replayMaxBytes
	replayMaxBytes = one * 10
	t.Cleanup(func() { replayMaxBytes = restore })

	var b strings.Builder
	b.WriteString(`{"meshghost_replay":1}` + "\n")
	for i := 0; i < 40; i++ {
		b.WriteString(line + "\n")
	}
	// Forty samples is nowhere near replayMaxSamples, so the count budget has
	// nothing to say about this file: it is refused purely on what it weighs.
	if _, err := parseReplay(strings.NewReader(b.String()), "fat.ndjson"); err == nil {
		t.Fatal("a clip whose samples cost 4x the memory budget was accepted -- " +
			"the budget was counting lines, and a line is worth anywhere from 126 B to 21.9 KB")
	}

	// The converse, so the budget is not simply refusing everything: the same
	// shape, inside the allowance.
	var ok strings.Builder
	ok.WriteString(`{"meshghost_replay":1}` + "\n")
	for i := 0; i < 5; i++ {
		ok.WriteString(line + "\n")
	}
	if _, err := parseReplay(strings.NewReader(ok.String()), "ok.ndjson"); err != nil {
		t.Fatalf("a clip inside the budget was refused: %v", err)
	}
}

func mustParseState(t *testing.T, line string) *protocol.State {
	t.Helper()
	var st protocol.State
	if err := json.Unmarshal([]byte(line), &st); err != nil {
		t.Fatal(err)
	}
	return &st
}

// TestAZipCannotMintMoreClipsThanTheRosterHasSeats: neither budget bounds the clip count, so many one-sample clips cost
// almost nothing, and every one takes a roster seat the room's real players share.
func TestAZipCannotMintMoreClipsThanTheRosterHasSeats(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "many.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	const clips = protocol.MaxRosterSize + 40
	for i := 0; i < clips; i++ {
		w, err := zw.Create(fmt.Sprintf("clip%03d.ndjson", i))
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(w, "%s\n%s\n", `{"meshghost_replay":1}`, `{"timestamp":1,"position":[0,0]}`)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()

	if st, err := os.Stat(path); err == nil {
		t.Logf("the archive is %d bytes for %d clips", st.Size(), clips)
	}

	all, err := loadReplayAll(path, true)
	if err != nil {
		t.Fatalf("the archive was refused outright: %v", err)
	}
	// Every clip is a replayPlayer and a goroutine, so the archive may yield no more than the roster seats.
	if len(all) > protocol.MaxRosterSize {
		t.Fatalf("a zip yielded %d clips, more than the %d seats a roster has",
			len(all), protocol.MaxRosterSize)
	}
}

// TestALongWaitIsClampedRatherThanOverflowed: speed divides the due time, so it multiplies a span ValidateState already
// cleared, and the conversion to a Duration can overflow.
func TestALongWaitIsClampedRatherThanOverflowed(t *testing.T) {
	// The dangerous window is not the largest span: ms*1e6 wraps modulo 2^64 and reads as negative only while the
	// product lands in [2^63, 2^64), roughly 9.22e12 to 1.84e13 ms; past that it wraps to a large positive the clamp
	// catches. So the maximum span was survivable and 1e13 was not.
	//
	// A var, not a const: as a constant expression the compiler refuses the overflow outright, and it wraps silently
	// only when the number arrives at runtime, as from a file it always does.
	wrapping := int64(1e13)
	naive := time.Duration(wrapping) * time.Millisecond
	if naive > 0 {
		t.Fatalf("test premise broken: time.Duration(%d)*time.Millisecond did not go negative (%v)",
			wrapping, naive)
	}
	if got := replayWaitFor(wrapping); got <= 0 || got > 50*time.Millisecond {
		t.Fatalf("a %d ms wait came out as %v -- a non-positive one makes time.After fire at once "+
			"and turns the playback loop into a hot spin holding c.mu", wrapping, got)
	}

	// Reachable? A clip's speed floors at 0.1 and the due time divides by it,
	// so the span is a timestamp difference times ten -- and 1e12 ms is well
	// inside what ValidateState accepts.
	if int64(float64(1e12)/replaySpeedMin) < wrapping || 1e12 > protocol.MaxTimestampMs {
		t.Fatalf("test premise broken: %d ms is not reachable from a valid clip", wrapping)
	}

	// And the largest span a file can produce, clamped too.
	span := int64(float64(protocol.MaxTimestampMs) / replaySpeedMin)
	if got := replayWaitFor(span); got <= 0 || got > 50*time.Millisecond {
		t.Fatalf("the maximum span (%d ms) came out as %v", span, got)
	}
	if got := replayWaitFor(10); got != 10*time.Millisecond {
		t.Fatalf("an ordinary 10ms wait came out as %v", got)
	}
}

// TestAttachingATrackReservesOnlyWhatTheClipMayKeep: the archive's edge budget is spent once at parse, but the attach
// happens once per clip sharing the track's recording_id, so each may reserve only what one clip keeps.
func TestAttachingATrackReservesOnlyWhatTheClipMayKeep(t *testing.T) {
	clip := &replayClip{
		file:      "c.ndjson",
		samples:   []protocol.State{{Timestamp: 0}, {Timestamp: 10}},
		trimFirst: 0, trimLast: 1 << 40,
	}
	// A source track far longer than a clip is allowed to keep.
	edges := make([]inputEdgeLine, replayMaxTrackEdges+5000)
	for i := range edges {
		edges[i] = inputEdgeLine{Ts: int64(i)}
	}
	clip.attachTrack(&inputTrack{file: "t.ndjson", edges: edges})

	if clip.track == nil {
		t.Fatal("no track attached")
	}
	if c := cap(clip.track.edges); c > replayMaxTrackEdges {
		t.Fatalf("the attach reserved capacity for %d edges, %d past what one clip may keep -- "+
			"sized by the file rather than by the cap, and paid once per clip that matches it",
			c, c-replayMaxTrackEdges)
	}
}

// TestAnInputTrackHeaderIsCheckedLikeTheWireWould: a track header's Labels, Axes and Source get the bounds the bridge
// applies, not only its edges.
func TestAnInputTrackHeaderIsCheckedLikeTheWireWould(t *testing.T) {
	long := strings.Repeat("x", bridge.MaxInputLabelLen+1)
	cases := map[string]string{
		"over-length label":  fmt.Sprintf(`{"meshghost_inputs":1,"labels":[%q]}`, long),
		"over-length axis":   fmt.Sprintf(`{"meshghost_inputs":1,"axes":[%q]}`, long),
		"over-length source": fmt.Sprintf(`{"meshghost_inputs":1,"source":%q}`, long),
	}
	for name, hdr := range cases {
		t.Run(name, func(t *testing.T) {
			body := hdr + "\n" + `{"ts":1,"f":1,"t":1,"m":0}` + "\n"
			if _, err := parseInputTrack(strings.NewReader(body), "t.ndjson"); err == nil {
				t.Fatalf("an input track with an %s was accepted -- _template/PROTOCOL.md "+
					"promises adapter authors the same bounds the bridge applies", name)
			}
		})
	}

	t.Run("an ordinary header is accepted", func(t *testing.T) {
		body := `{"meshghost_inputs":1,"source":"pad","labels":["jump"],"axes":["lx"]}` + "\n" +
			`{"ts":1,"f":1,"t":1,"m":1}` + "\n"
		if _, err := parseInputTrack(strings.NewReader(body), "t.ndjson"); err != nil {
			t.Fatalf("an ordinary input track was refused: %v", err)
		}
	})
}

// TestAZipsInputTrackIsNotAttachedForAnAdapterThatNeverAskedForOne: a zip attaches its track at parse, so the
// capability test must hold there too, or clip.track != nil short-circuits the disk path's own gate.
func TestAZipsInputTrackIsNotAttachedForAnAdapterThatNeverAskedForOne(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pair.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	w, _ := zw.Create("run.ndjson")
	fmt.Fprintf(w, "%s\n%s\n",
		`{"meshghost_replay":1,"recording_id":"r1"}`, `{"timestamp":1,"position":[0,0]}`)
	w, _ = zw.Create("run.inputs.ndjson")
	fmt.Fprintf(w, "%s\n%s\n",
		`{"meshghost_inputs":1,"recording_id":"r1","labels":["jump"]}`, `{"ts":1,"f":1,"t":1,"m":1}`)
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()

	withTracks, err := loadReplayAll(path, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(withTracks) != 1 || withTracks[0].clip.track == nil {
		t.Fatal("test premise broken: the track did not attach even for an adapter that asked")
	}

	without, err := loadReplayAll(path, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(without) != 1 {
		t.Fatalf("got %d clips, want 1", len(without))
	}
	if without[0].clip.track != nil {
		t.Fatal("a zip's input track was attached for an adapter that never declared input_tracks -- " +
			"the disk path gates this, and the zip path's attach at parse time then made that gate " +
			"a no-op, because it tests clip.track != nil")
	}
}
