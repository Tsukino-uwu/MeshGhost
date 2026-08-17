package protocol

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
)

// TestIsValidPosition covers the newest safety check added to this
// package — found with zero test coverage anywhere in the codebase while
// doing a full documentation/code sweep, despite being the check that
// stops a peer wedging a NaN/±Inf/absurd-magnitude value onto the wire.
func TestIsValidPosition(t *testing.T) {
	cases := []struct {
		name string
		pos  []float64
		want bool
	}{
		{"empty", nil, true},
		{"ordinary", []float64{1, 2, 3}, true},
		{"at max bound", []float64{MaxPositionComponent, -MaxPositionComponent}, true},
		{"just past max bound", []float64{MaxPositionComponent + 1}, false},
		{"NaN", []float64{math.NaN()}, false},
		{"+Inf", []float64{math.Inf(1)}, false},
		{"-Inf", []float64{math.Inf(-1)}, false},
		{"one bad component among good ones", []float64{1, math.NaN(), 2}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsValidPosition(tc.pos); got != tc.want {
				t.Errorf("IsValidPosition(%v) = %v, want %v", tc.pos, got, tc.want)
			}
		})
	}
}

// TestValidateState covers the extracted, shared check that replaced the
// verbatim-duplicated validation block previously carried separately by
// relay and core.
func TestValidateState(t *testing.T) {
	valid := func() State {
		return State{
			PlayerID: "p1",
			AreaID:   "a",
			Position: []float64{1, 2},
			Anim:     "idle",
		}
	}

	if !ValidateState(valid()) {
		t.Fatal("a valid state was rejected")
	}

	t.Run("oversized position", func(t *testing.T) {
		st := valid()
		st.Position = make([]float64, MaxPositionLen+1)
		if ValidateState(st) {
			t.Fatal("oversized position was accepted")
		}
	})
	t.Run("oversized extras", func(t *testing.T) {
		st := valid()
		st.Extras = map[string]any{"junk": string(make([]byte, MaxExtrasBytes+1))}
		if ValidateState(st) {
			t.Fatal("oversized extras was accepted")
		}
	})
	t.Run("oversized area_id", func(t *testing.T) {
		st := valid()
		st.AreaID = string(make([]byte, MaxAreaIDLen+1))
		if ValidateState(st) {
			t.Fatal("oversized area_id was accepted")
		}
	})
	t.Run("oversized anim", func(t *testing.T) {
		st := valid()
		st.Anim = string(make([]byte, MaxAnimLen+1))
		if ValidateState(st) {
			t.Fatal("oversized anim was accepted")
		}
	})
	t.Run("oversized orientation", func(t *testing.T) {
		st := valid()
		st.Orientation = make([]byte, MaxOrientationBytes+1)
		if ValidateState(st) {
			t.Fatal("oversized orientation was accepted")
		}
	})
	t.Run("non-finite position", func(t *testing.T) {
		st := valid()
		st.Position = []float64{math.NaN()}
		if ValidateState(st) {
			t.Fatal("non-finite position was accepted")
		}
	})
}

// TestOpaqueIdentifiersMustBeValidUTF8 is the named form of a defect the
// fuzzer found (its reproducing input is kept in
// testdata/fuzz/FuzzValidateEventIsStableAcrossTheWire, where `go test` replays
// it, but a seed file explains nothing about why it matters).
//
// The rule: an opaque identifier is only ever compared by equality, and a
// string that is not valid UTF-8 does not survive JSON — encoding/json swaps
// each invalid byte for U+FFFD. So the sender's key and every receiver's key
// are different strings, and equality silently stops working. The replacement
// also expands one byte into three, which is how it surfaced: a corr_id that
// passed the length check before marshaling failed it afterwards, so a client
// accepted an event the relay would then silently drop.
func TestOpaqueIdentifiersMustBeValidUTF8(t *testing.T) {
	// Valid UTF-8 and comfortably short. Non-ASCII on purpose: the rule is
	// about well-formedness, never about restricting anyone to ASCII.
	const ok = "route103:rare-candy-ünïcode"
	// A lone continuation byte: syntactically impossible UTF-8.
	const bad = "route103:\xb4\xe5"

	if !ValidOpaqueString(ok, 128) {
		t.Fatalf("a valid non-ASCII identifier was rejected")
	}
	if ValidOpaqueString(bad, 128) {
		t.Fatalf("an invalid-UTF-8 identifier was accepted")
	}

	if ValidateEvent(Event{CorrID: bad}) {
		t.Errorf("an event with an invalid-UTF-8 corr_id was accepted")
	}
	if ValidateEvent(Event{To: bad}) {
		t.Errorf("an event addressed to an invalid-UTF-8 player_id was accepted")
	}
	if ValidateLease(Lease{Op: LeaseClaim, Key: bad}) {
		t.Errorf("a lease claim on an invalid-UTF-8 key was accepted")
	}
	if ValidateEscrow(Escrow{Op: EscrowOpen, ID: bad, With: "p2"}) {
		t.Errorf("an exchange with an invalid-UTF-8 id was accepted")
	}
	if ValidateState(State{AreaID: bad}) {
		t.Errorf("a state with an invalid-UTF-8 area_id was accepted")
	}
	if ValidateState(State{Anim: bad}) {
		t.Errorf("a state with an invalid-UTF-8 anim was accepted")
	}

	// And the legitimate cases still pass, so this cannot have been "fixed"
	// by rejecting everything.
	if !ValidateEvent(Event{CorrID: ok}) || !ValidateLease(Lease{Op: LeaseClaim, Key: ok}) ||
		!ValidateState(State{AreaID: ok, Anim: ok}) {
		t.Errorf("valid identifiers were rejected by the new UTF-8 check")
	}
}

// TestValidateWorldBounds covers the world plane's refusals. Both identifiers
// go through ValidOpaqueString, so both are length- and UTF-8-checked.
func TestValidateWorldBounds(t *testing.T) {
	ok := World{Op: WorldSet, Authority: "sim", Key: "e0", Blob: json.RawMessage(`{"gen":1}`)}
	if !ValidateWorld(ok) {
		t.Fatal("a plain world write was rejected")
	}
	if ValidateWorld(World{Op: "nonsense", Authority: "sim", Key: "e0"}) {
		t.Fatal("an unknown op was accepted")
	}
	if ValidateWorld(World{Op: WorldSet, Key: "e0"}) {
		t.Fatal("a write with no authority was accepted -- it could never be lease-gated")
	}
	if ValidateWorld(World{Op: WorldSet, Authority: "sim"}) {
		t.Fatal("a write with no key was accepted")
	}
	long := World{Op: WorldSet, Authority: strings.Repeat("a", MaxLeaseKeyLen+1), Key: "e0"}
	if ValidateWorld(long) {
		t.Fatal("an over-length authority was accepted")
	}
	if ValidateWorld(World{Op: WorldSet, Authority: "sim", Key: strings.Repeat("k", MaxWorldKeyLen+1)}) {
		t.Fatal("an over-length key was accepted")
	}
	big := World{Op: WorldSet, Authority: "sim", Key: "e0",
		Blob: json.RawMessage(strings.Repeat("x", MaxWorldBlobBytes+1))}
	if ValidateWorld(big) {
		t.Fatal("an oversized blob was accepted")
	}
	// The UTF-8 half, which is the one that fails silently rather than loudly.
	if ValidateWorld(World{Op: WorldSet, Authority: "\xff", Key: "e0"}) {
		t.Fatal("a non-UTF-8 authority was accepted -- it would compare unequal to the " +
			"lease key it names once JSON replaced the invalid bytes")
	}
}

// TestValidateWorldStateBounds is the receive-side check: a hostile relay is
// not trusted to have enforced its own limits.
func TestValidateWorldStateBounds(t *testing.T) {
	if !ValidateWorldState(WorldState{Authority: "sim", Holder: "p1", Seq: 1,
		Entries: []WorldEntry{{Key: "e0", Blob: json.RawMessage(`1`)}}}) {
		t.Fatal("a plain world state was rejected")
	}
	if ValidateWorldState(WorldState{Authority: "sim", Entries: []WorldEntry{{Key: ""}}}) {
		t.Fatal("an entry with no key was accepted")
	}
	if ValidateWorldState(WorldState{Authority: "sim", Entries: []WorldEntry{
		{Key: "e0", Blob: json.RawMessage(strings.Repeat("x", MaxWorldBlobBytes+1))}}}) {
		t.Fatal("an oversized blob was accepted from the relay")
	}
	too := make([]WorldEntry, MaxWorldKeysPerRoom+1)
	for i := range too {
		too[i] = WorldEntry{Key: "e"}
	}
	if ValidateWorldState(WorldState{Authority: "sim", Entries: too}) {
		t.Fatal("more entries than a room may hold were accepted")
	}
}
