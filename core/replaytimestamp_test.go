package core

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// A replay file is UNTRUSTED INPUT: clips are shared between players, and
// StartReplays loads everything in replay/active/ the moment the adapter
// attaches -- i.e. the moment somebody launches their game after dropping a
// friend's clip in.
//
// parseReplay checked that timestamps did not go BACKWARDS and nothing else, so
// any int64 was accepted. sleepUntil then computed
//
//	wait := time.Duration(due-now) * time.Millisecond
//	if wait > 50*time.Millisecond { wait = 50 * time.Millisecond }
//
// and time.Duration is int64 NANOSECONDS, so a gap past ~9.22e12 ms wrapped to a
// NEGATIVE duration -- which sails past the 50ms clamp, makes time.After fire
// immediately, and leaves `now >= due` false. A tight spin on one full core for
// the rest of the session, from a two-line file, with the ghost frozen on its
// first position.
//
// protocol.MaxTimestampMs closes it at the parse, which is the only layer that
// can: ValidateState is shared with the wire, and every sample in a clip goes
// through it.
func TestAReplayWithAnOverflowingTimestampIsRefused(t *testing.T) {
	hostile := []protocol.State{
		{Seq: 1, Timestamp: 0, AreaID: "a", Position: []float64{0, 0}},
		// Monotonic, so the ordering check this file used to rely on passes.
		{Seq: 2, Timestamp: 10_000_000_000_000, AreaID: "a", Position: []float64{1, 0}},
	}

	// The gap really would have wrapped: assert the arithmetic, so this test
	// still means something if the constant is ever widened.
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

	// A negative timestamp is refused for the same reason -- it would double the
	// worst-case span.
	_, err = parseReplay(bytes.NewReader(clipBytes(nil, []protocol.State{
		{Seq: 1, Timestamp: -1, AreaID: "a", Position: []float64{0, 0}},
	})), "negative")
	if err == nil {
		t.Fatal("a clip with a timestamp before the epoch was accepted")
	}

	// And an ordinary clip still loads, so the bound has not simply broken
	// replays.
	clip, err := parseReplay(bytes.NewReader(clipBytes(nil, walkStates(4, 50))), "ordinary")
	if err != nil {
		t.Fatalf("an ordinary clip was refused by the new bound: %v", err)
	}
	if len(clip.samples) != 4 {
		t.Fatalf("ordinary clip parsed %d samples, want 4", len(clip.samples))
	}
}
