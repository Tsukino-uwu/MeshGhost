package protocol

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// The loss cover's two pure halves (ADR 0045): a delta built by BuildPrev and
// undone by ApplyPrev must give back exactly the previous sample, for every
// kind of difference two consecutive samples can have -- and the delta must
// survive the wire, because the relay decodes and re-encodes every state.

func roundTrip(t *testing.T, prev, cur State) State {
	t.Helper()
	cur.Prev = BuildPrev(&prev, &cur)
	// Through JSON, the way the relay and the receiving core see it.
	b, err := json.Marshal(cur)
	if err != nil {
		t.Fatal(err)
	}
	var wire State
	if err := json.Unmarshal(b, &wire); err != nil {
		t.Fatal(err)
	}
	got, ok := ApplyPrev(&wire)
	if !ok {
		t.Fatal("ApplyPrev found no prev after the wire")
	}
	return got
}

// sameSample compares what the receiver's buffer would hold; Prev is never
// part of that (a reconstructed sample carries none).
func sameSample(t *testing.T, want, got State) {
	t.Helper()
	// JSON normalises numbers in Extras (int -> float64), so compare through
	// the wire on both sides.
	wb, _ := json.Marshal(want)
	gb, _ := json.Marshal(got)
	var w, g map[string]any
	_ = json.Unmarshal(wb, &w)
	_ = json.Unmarshal(gb, &g)
	if !reflect.DeepEqual(w, g) {
		t.Fatalf("reconstructed sample differs\n want %s\n  got %s", wb, gb)
	}
}

func TestPrevRoundTripsEveryKindOfDifference(t *testing.T) {
	base := State{PlayerID: "p1", Seq: 10, Timestamp: 1000, AreaID: "a",
		Position: []float64{1, 2}, Orientation: json.RawMessage(`"west"`),
		Anim: "walk", Extras: map[string]any{"k": "v", "n": float64(3)}}
	cases := []struct {
		name string
		prev State
	}{
		{"only seq and timestamp differ", func() State { p := base; p.Seq = 9; p.Timestamp = 933; return p }()},
		{"position differs", func() State { p := base; p.Position = []float64{0, 2}; return p }()},
		{"prev had no position", func() State { p := base; p.Position = nil; return p }()},
		{"area and anim differ", func() State { p := base; p.AreaID = "b"; p.Anim = "idle"; return p }()},
		{"orientation differs", func() State { p := base; p.Orientation = json.RawMessage(`"east"`); return p }()},
		{"prev had no orientation", func() State { p := base; p.Orientation = nil; return p }()},
		{"an extras value differs", func() State {
			p := base
			p.Extras = map[string]any{"k": "old", "n": float64(3)}
			return p
		}()},
		{"prev had an extra key cur lacks", func() State {
			p := base
			p.Extras = map[string]any{"k": "v", "n": float64(3), "gone": true}
			return p
		}()},
		{"cur has a key prev lacked", func() State {
			p := base
			p.Extras = map[string]any{"k": "v"}
			return p
		}()},
		{"prev had no extras", func() State { p := base; p.Extras = nil; return p }()},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := roundTrip(t, tc.prev, base)
			want := tc.prev
			want.Prev = nil
			sameSample(t, want, got)
		})
	}
	// And the mirror image: cur has no extras, prev had some.
	t.Run("cur has no extras and prev had", func(t *testing.T) {
		cur := base
		cur.Extras = nil
		prev := base
		prev.Seq = 9
		got := roundTrip(t, prev, cur)
		sameSample(t, prev, got)
	})
}

func TestPrevIsADeltaNotACopy(t *testing.T) {
	prev := State{Seq: 1, Timestamp: 1, AreaID: "a", Position: []float64{1, 2}, Anim: "walk",
		Extras: map[string]any{"k": "v", "big": strings.Repeat("x", 200)}}
	cur := prev
	cur.Seq, cur.Timestamp = 2, 67
	cur.Position = []float64{1, 3}
	d := BuildPrev(&prev, &cur)
	if d.AreaID != nil || d.Anim != nil || d.Extras != nil || d.ExtrasNone || d.Orientation != nil {
		t.Fatalf("unchanged fields were carried: %+v", d)
	}
	if len(d.Position) != 2 || d.Position[1] != 2 {
		t.Fatalf("the changed position was not carried: %+v", d.Position)
	}
	b, _ := json.Marshal(d)
	if len(b) > 80 {
		t.Fatalf("delta is %d bytes for a one-step move; it is not a delta: %s", len(b), b)
	}
}

func TestApplyPrevDoesNotTouchTheCarryingState(t *testing.T) {
	cur := State{Seq: 2, Extras: map[string]any{"k": "v"}, Position: []float64{5}}
	cur.Prev = &StatePrev{Seq: 1, Extras: map[string]any{"k": "old", "z": 1}, Position: []float64{4}}
	got, _ := ApplyPrev(&cur)
	if cur.Extras["k"] != "v" || len(cur.Extras) != 1 || cur.Position[0] != 5 {
		t.Fatalf("the carrying state was mutated: %+v", cur)
	}
	if got.Extras["k"] != "old" || got.Extras["z"] != 1 || got.Position[0] != 4 || got.Prev != nil {
		t.Fatalf("reconstruction wrong: %+v", got)
	}
}

func TestValidateStateBoundsTheCarriedPrev(t *testing.T) {
	ok := State{AreaID: "a", Position: []float64{1, 2}, Anim: "walk"}
	if !ValidateState(ok) {
		t.Fatal("fixture invalid")
	}
	bad := func(p StatePrev) State { s := ok; s.Prev = &p; return s }
	huge := strings.Repeat("a", MaxAreaIDLen+1)
	cases := map[string]State{
		"non-finite prev position": bad(StatePrev{Position: []float64{1e308}}),
		"over-long prev position":  bad(StatePrev{Position: make([]float64, MaxPositionLen+1)}),
		"over-long prev area":      bad(StatePrev{AreaID: &huge}),
		"over-long prev anim":      bad(StatePrev{Anim: &huge}),
		"oversized prev orientation": bad(StatePrev{Orientation: json.RawMessage(
			`"` + strings.Repeat("o", MaxOrientationBytes) + `"`)}),
		"oversized prev extras": bad(StatePrev{Extras: map[string]any{"k": strings.Repeat("x", MaxExtrasBytes)}}),
	}
	for name, st := range cases {
		if ValidateState(st) {
			t.Errorf("%s: accepted", name)
		}
		if StateRejectReason(st) == "" {
			t.Errorf("%s: no reject reason", name)
		}
	}
	fine := bad(StatePrev{Seq: 1, Position: []float64{0, 0}})
	if !ValidateState(fine) {
		t.Fatal("a well-formed prev was rejected")
	}
}
