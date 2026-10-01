package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestValidateStateDoesNotImplyTheLineFits: every per-field bound is enforced on its own and nothing sums them, so a
// maximal legal state carrying a prev serializes past MaxLineBytes. The sender handles it (core/sending.go drops the
// prev, then refuses); tightening a per-field bound instead would cost every ordinary state a limit it never nears.
func TestValidateStateDoesNotImplyTheLineFits(t *testing.T) {
	// Maximal by construction: each field grows until ValidateState refuses it, then steps back one, so the fixture
	// stays maximal when a bound moves.
	fill := func(n int) string { return strings.Repeat("a", n) }
	// Longest float literals Go will print, so position carries its worst case.
	pos := []float64{1.2345678901234567, -2.3456789012345678, 3.4567890123456789, -4.5678901234567891,
		5.6789012345678912, -6.7890123456789123, 7.8901234567891234, -8.9012345678912345}
	orient := func() json.RawMessage {
		best := json.RawMessage(`[]`)
		for n := 1; n <= 64; n++ {
			cand := json.RawMessage(`[` + strings.TrimSuffix(strings.Repeat("1.2345678901234567,", n), ",") + `]`)
			if JSONWireLen(cand) > MaxOrientationBytes || !rawJSONDepthWithinLimit(cand) {
				break
			}
			best = cand
		}
		return best
	}()
	biggestExtras := func() map[string]any {
		best := map[string]any{"b": ""}
		for n := 1; n <= MaxExtrasBytes; n++ {
			cand := map[string]any{"b": fill(n)}
			if !extrasWithinLimit(cand) {
				break
			}
			best = cand
		}
		return best
	}()

	st := State{
		PlayerID:    "p1",
		Seq:         1 << 40,
		Timestamp:   1_780_000_000_000,
		AreaID:      fill(MaxAreaIDLen),
		Anim:        fill(MaxAnimLen),
		Position:    pos,
		Orientation: orient,
		Extras:      biggestExtras,
	}
	prevArea, prevAnim := fill(MaxAreaIDLen), fill(MaxAnimLen)
	prev := StatePrev{
		Seq:         2,
		Timestamp:   1_780_000_000_001,
		AreaID:      &prevArea,
		Anim:        &prevAnim,
		Position:    pos,
		Orientation: orient,
		Extras:      biggestExtras,
	}
	st.Prev = &prev

	if !ValidateState(st) {
		t.Fatalf("the fixture is not a legal state, so it proves nothing: %s", StateRejectReason(st))
	}

	// The envelope, not the bare state, is what the reader measures; the bare state alone is one byte under the cap.
	payload, err := json.Marshal(st)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	wire := AppendEnvelope(nil, TypeState, payload)
	t.Logf("a maximal legal state with a prev: payload %d bytes, envelope %d, against MaxLineBytes=%d",
		len(payload), len(wire), MaxLineBytes)

	if len(wire) <= MaxLineBytes {
		t.Fatalf("a maximal legal state now fits in %d bytes -- if a bound was tightened on purpose "+
			"this test should be replaced by the assertion it currently forbids (valid implies "+
			"sendable), and core/sending.go's oversized-state path becomes dead code worth removing",
			MaxLineBytes)
	}

	// The sender relies on this: dropping the carried prev, pure redundancy, brings a legal state back inside the cap.
	without := st
	without.Prev = nil
	shorterPayload, err := json.Marshal(without)
	if err != nil {
		t.Fatalf("marshal without prev: %v", err)
	}
	shorter := AppendEnvelope(nil, TypeState, shorterPayload)
	if len(shorter) > MaxLineBytes {
		t.Fatalf("a legal state without its prev is still %d bytes, over the %d cap -- core/sending.go "+
			"drops prev first and assumes that is enough, which would no longer be true",
			len(shorter), MaxLineBytes)
	}
}
