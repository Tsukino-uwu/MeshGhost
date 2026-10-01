package protocol

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// extrasNear builds an extras map close to the cap, its keys prefixed so two of them can be made disjoint.
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

	// Both halves are legal, which is the point: there is no bad field to refuse, and the line fits the wire.
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
		t.Fatalf("a reconstruction carrying %d bytes of extras was accepted, against a %d cap -- "+
			"the adapter is promised %d and got %d", len(merged), MaxExtrasBytes, MaxExtrasBytes, len(merged))
	}
}

// TestAnOrdinaryPrevStillReconstructs: the union bound must not refuse ordinary loss cover, whose extras overlap the
// state's.
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
