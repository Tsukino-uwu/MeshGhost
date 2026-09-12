package protocol

// X1-2 from the 2026-09-12 adversarial review's parity cell.
//
// ValidateState bounds a state's extras and validPrev bounds its prev's extras,
// each on its own. ApplyPrev then builds the UNION of the two, and nothing
// bounded what they add up to -- so a reconstruction carrying twice the
// documented cap went into the interpolation buffer and out to the adapter as
// render_remote.state.extras.
//
// It is the third instance of the class validPrev's own comment names: a check
// applied to the state and not to what the delta makes of it. The other two
// were the orientation depth (2026-09-08) and the timestamp (2026-09-12).

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// extrasNear builds an extras map close to the cap, with keys carrying the
// given prefix so two of them can be made disjoint.
func extrasNear(t *testing.T, prefix string) map[string]any {
	t.Helper()
	m := map[string]any{}
	for i := 0; ; i++ {
		k := fmt.Sprintf("%s%03d", prefix, i)
		m[k] = strings.Repeat("v", 8)
		b, err := json.Marshal(m)
		if err != nil {
			t.Fatal(err)
		}
		if len(b) > MaxExtrasBytes-40 {
			delete(m, k)
			return m
		}
	}
}

func TestTheExtrasUnionOfAStateAndItsPrevIsBounded(t *testing.T) {
	cur := extrasNear(t, "a")
	prv := extrasNear(t, "b")

	st := State{
		PlayerID: "p1", Timestamp: 1000, AreaID: "town", Position: []float64{1, 2},
		Extras: cur,
		Prev:   &StatePrev{Seq: 1, Timestamp: 900, Extras: prv},
	}

	// BOTH HALVES ARE LEGAL, which is the whole point -- there is no bad field
	// to refuse, and the line comfortably fits the wire.
	if !ValidateState(st) {
		t.Fatalf("test premise broken: the carrying state is refused (%s)", StateRejectReason(st))
	}
	line, err := json.Marshal(st)
	if err != nil {
		t.Fatal(err)
	}
	if len(line) > MaxPayloadBytes {
		t.Fatalf("test premise broken: the whole line is %d bytes, over the %d cap -- "+
			"this has to be reachable on the wire to be a finding", len(line), MaxPayloadBytes)
	}
	t.Logf("the carrying line is %d bytes, inside the %d cap", len(line), MaxPayloadBytes)

	got, ok := ApplyPrev(&st)
	if ok {
		merged, err := json.Marshal(got.Extras)
		if err != nil {
			t.Fatal(err)
		}
		// Before the fix: accepted, at ~2x MaxExtrasBytes.
		t.Fatalf("a reconstruction carrying %d bytes of extras was accepted, against a %d cap -- "+
			"the adapter is promised %d and got %d", len(merged), MaxExtrasBytes, MaxExtrasBytes, len(merged))
	}
}

// The converse, so the bound is not simply refusing loss cover: an ordinary
// prev, whose extras overlap the state's, still reconstructs.
func TestAnOrdinaryPrevStillReconstructs(t *testing.T) {
	st := State{
		PlayerID: "p1", Timestamp: 1000, AreaID: "town", Position: []float64{3, 4},
		Extras: map[string]any{"hp": 10.0, "face": 2.0},
		Prev: &StatePrev{
			Seq: 1, Timestamp: 900,
			Position: []float64{1, 2},
			Extras:   map[string]any{"hp": 9.0},
		},
	}
	if !ValidateState(st) {
		t.Fatalf("setup: %s", StateRejectReason(st))
	}
	got, ok := ApplyPrev(&st)
	if !ok {
		t.Fatal("an ordinary prev was refused -- the union bound is eating legitimate loss cover")
	}
	if got.Extras["hp"] != 9.0 || got.Extras["face"] != 2.0 {
		t.Fatalf("the reconstruction lost or changed a key: %v", got.Extras)
	}
	if got.Timestamp != 900 || got.Seq != 1 {
		t.Fatalf("the reconstruction is not the previous sample: seq=%d ts=%d", got.Seq, got.Timestamp)
	}
}
