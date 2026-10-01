package core

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestAReplayWithAnOverflowingTimestampIsRefused: a clip is untrusted input, shared between players and loaded when the
// adapter attaches, so the parse bounds every timestamp and no gap between two samples overflows a time.Duration.
func TestAReplayWithAnOverflowingTimestampIsRefused(t *testing.T) {
	hostile := []protocol.State{
		{Seq: 1, Timestamp: 0, AreaID: "a", Position: []float64{0, 0}},
		// Monotonic, so the ordering check alone passes it.
		{Seq: 2, Timestamp: 10_000_000_000_000, AreaID: "a", Position: []float64{1, 0}},
	}

	// Assert the gap really wraps, so the test still means something if the bound is ever widened.
	gap := hostile[1].Timestamp - hostile[0].Timestamp
	if d := time.Duration(gap) * time.Millisecond; d >= 0 {
		t.Fatalf("precondition: %d ms was expected to overflow time.Duration, got %v", gap, d)
	}

	_, err := parseReplay(bytes.NewReader(clipBytes(nil, hostile)), "hostile")
	if err == nil {
		t.Fatal("a clip whose timestamp gap overflows time.Duration was accepted: " +
			"sleepUntil's 50ms clamp does not fire on a negative wait, so playback spins " +
			"a full core until StopReplays")
	}
	if !strings.Contains(strings.ToLower(err.Error()), "sample") &&
		!strings.Contains(strings.ToLower(err.Error()), "timestamp") {
		t.Logf("refused, but the message names neither the sample nor the timestamp: %v", err)
	}

	// A negative timestamp would double the worst-case span.
	_, err = parseReplay(bytes.NewReader(clipBytes(nil, []protocol.State{
		{Seq: 1, Timestamp: -1, AreaID: "a", Position: []float64{0, 0}},
	})), "negative")
	if err == nil {
		t.Fatal("a clip with a timestamp before the epoch was accepted")
	}

	clip, err := parseReplay(bytes.NewReader(clipBytes(nil, walkStates(4, 50))), "ordinary")
	if err != nil {
		t.Fatalf("an ordinary clip was refused by the new bound: %v", err)
	}
	if len(clip.samples) != 4 {
		t.Fatalf("ordinary clip parsed %d samples, want 4", len(clip.samples))
	}
}
