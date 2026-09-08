package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

// PASSING ValidateState DOES NOT MEAN THE LINE FITS, and this test exists so
// nobody assumes otherwise -- including by "fixing" the state fuzzer with the
// obvious assertion, which would fail on a state that is entirely legal.
//
// Every per-field bound is enforced independently: area_id and anim at 256
// bytes each, orientation at 256, extras at 1024, up to 8 position components.
// Nothing anywhere adds them up, and a carried prev (ADR 0045) meets the same
// bounds again on its own fields. So a maximal-but-legal state serializes past
// MaxLineBytes while ValidateState returns true for it -- measured 2026-09-08
// at just over 4KB against the 4096 cap.
//
// The consequence was live and silent, which is why this is pinned rather than
// left as a comment: the relay's read loop turns an oversized line into
// bufio.ErrTooLong, which ENDS THE READ LOOP AND DROPS THE CONNECTION with no
// reject (relay.go says so in as many words -- an oversized line never reaches
// the callback). The core read EOF, classified it transient, reconnected, was
// assigned a NEW player_id, and every peer saw despawn/respawn -- looping for as
// long as the game stayed in that state, with nothing anywhere naming a size.
// Redundancy is on by default at the shipped 15Hz, so prev is attached in the
// default configuration.
//
// The fix is on the SEND side (core/sending.go drops prev, then refuses), not
// here: tightening a per-field bound until the sum fits would cost every
// ordinary state a limit it never approaches, to bound a combination no real
// adapter produces.
func TestValidateStateDoesNotImplyTheLineFits(t *testing.T) {
	// Built MAXIMAL BY CONSTRUCTION rather than by hand-counted bytes: each
	// field is grown until ValidateState refuses it and then stepped back one.
	// A hand-sized fixture silently stops being maximal the moment any bound
	// moves, and then this test passes for the wrong reason.
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

	// THE ENVELOPE, not the bare state -- that is what goes on the wire and what
	// the reader measures. The bare state is 4095 bytes here, one under the cap,
	// which is exactly the trap: measuring the payload alone says this is fine.
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

	// And the half the sender relies on: dropping the carried prev, which is
	// pure redundancy, always brings a legal state back inside the cap.
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
