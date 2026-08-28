package protocol

import (
	"encoding/json"
	"math"
	"strings"
	"sync"
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

// TestJSONWireLenMatchesWhatMarshalWrites pins the helper to the encoder it
// models: whatever encoding/json actually emits for a raw value must never be
// longer than JSONWireLen said it would be. A bound that under-counts is the
// bug this whole helper exists to fix, so under-counting is what this checks —
// over-counting (the whitespace it declines to credit) is allowed.
func TestJSONWireLenMatchesWhatMarshalWrites(t *testing.T) {
	for _, raw := range []string{
		`1`, `null`, `{"gen":1}`, `"plain"`, `{ "a" : [1, 2] }`,
		`"&"`, `"<a>&<b>"`, `{"url":"a?x=1&y=2"}`,
		`"` + strings.Repeat("&", 128) + `"`,
		"\"  \"",
	} {
		enc, err := json.Marshal(json.RawMessage(raw))
		if err != nil {
			t.Fatalf("marshal %q: %v", raw, err)
		}
		if got := JSONWireLen([]byte(raw)); got < len(enc) {
			t.Errorf("JSONWireLen(%q) = %d, but the encoder wrote %d bytes -- "+
				"a bound measured with this would pass here and fail on the wire", raw, got, len(enc))
		}
	}
}

// TestBlobBoundsCountEscapedBytes is the regression for the input CI's
// FuzzValidateWorldIsStableAcrossTheWire found on 2026-08-22: a blob that fits
// in hand and does not fit once encoding/json has escaped every '&' in it.
// Accepting it means the sender validates, the relay forwards, and the far
// side rejects a write nobody can explain -- and, on UDP, a datagram built to
// a 1200-byte budget that is six times over it.
func TestBlobBoundsCountEscapedBytes(t *testing.T) {
	// Raw length comfortably inside the limit; escaped length past it.
	blob := json.RawMessage(`"` + strings.Repeat("&", MaxWorldBlobBytes/3) + `"`)
	if len(blob) > MaxWorldBlobBytes {
		t.Fatalf("test blob is %d raw bytes, already over the limit -- it proves nothing", len(blob))
	}
	if ValidateWorld(World{Op: WorldSet, Authority: "sim", Key: "e0", Blob: blob}) {
		t.Error("a world blob that only fits before escaping was accepted")
	}
	if ValidateWorldState(WorldState{Authority: "sim", Holder: "p1",
		Entries: []WorldEntry{{Key: "e0", Blob: blob}}}) {
		t.Error("a world-state blob that only fits before escaping was accepted")
	}

	ev := json.RawMessage(`"` + strings.Repeat("&", MaxEventBytes/3) + `"`)
	if ValidateEvent(Event{Payload: ev}) {
		t.Error("an event payload that only fits before escaping was accepted")
	}

	esc := json.RawMessage(`"` + strings.Repeat("&", MaxEscrowBlobBytes/3) + `"`)
	if ValidateEscrow(Escrow{Op: EscrowDeposit, ID: "trade-1", Blob: esc}) {
		t.Error("an escrow blob that only fits before escaping was accepted")
	}
}

// TestClampSendHzAndClampReceiveHzDifferOnZero pins the ONE rule that
// distinguishes the two functions: zero means "use the default rate" for a send
// rate and "uncapped" for a receive cap, so ClampSendHz(0) is DefaultSendHz and
// ClampReceiveHz(0) is 0. Neither function had a direct unit test until
// 2026-08-27 -- the behaviour was covered end to end by a relay test, which
// would not have caught the two being swapped at a call site, and swapping them
// is the mistake the shared [MinSendHz, MaxSendHz] tail makes easy.
func TestClampSendHzAndClampReceiveHzDifferOnZero(t *testing.T) {
	for _, hz := range []int{0, -1, -1000} {
		if got := ClampSendHz(hz); got != DefaultSendHz {
			t.Errorf("ClampSendHz(%d) = %d, want DefaultSendHz (%d): a send rate has a sensible default", hz, got, DefaultSendHz)
		}
		if got := ClampReceiveHz(hz); got != 0 {
			t.Errorf("ClampReceiveHz(%d) = %d, want 0: a receive cap has no default, only off", hz, got)
		}
	}

	// Everything else about the two is identical, and that is the point: a
	// positive value is clamped into range rather than refused, because neither
	// a relay nor a client may fail over a cosmetic tuning knob.
	for _, f := range []struct {
		name string
		fn   func(int) int
	}{{"ClampSendHz", ClampSendHz}, {"ClampReceiveHz", ClampReceiveHz}} {
		if got := f.fn(MinSendHz - 1); got != MinSendHz {
			t.Errorf("%s(%d) = %d, want %d", f.name, MinSendHz-1, got, MinSendHz)
		}
		if got := f.fn(MaxSendHz + 1); got != MaxSendHz {
			t.Errorf("%s(%d) = %d, want %d", f.name, MaxSendHz+1, got, MaxSendHz)
		}
		if got := f.fn(MinSendHz); got != MinSendHz {
			t.Errorf("%s(%d) = %d, want it unchanged", f.name, MinSendHz, got)
		}
		if got := f.fn(MaxSendHz); got != MaxSendHz {
			t.Errorf("%s(%d) = %d, want it unchanged", f.name, MaxSendHz, got)
		}
	}
}

// The exact byte where Extras stops being acceptable. Pinned so that any future
// attempt to compute this length more cheaply — a hand-written size walker was
// considered and rejected in 2026-08-28's efficiency pass — cannot move the
// boundary by one byte without a test saying so. A moved boundary is not a
// performance regression, it is a state the relay accepts and the core rejects.
func TestExtrasLimitIsExactlyMarshalLength(t *testing.T) {
	// Build a single-key map whose marshaled form lands on a chosen length.
	// {"k":"<pad>"} is 8 bytes of syntax around the padding.
	const overhead = len(`{"k":""}`)
	atLength := func(n int) map[string]any {
		return map[string]any{"k": strings.Repeat("a", n-overhead)}
	}

	exact := atLength(MaxExtrasBytes)
	if b, err := json.Marshal(exact); err != nil || len(b) != MaxExtrasBytes {
		t.Fatalf("fixture is wrong: len=%d err=%v, wanted exactly %d", len(b), err, MaxExtrasBytes)
	}
	if !ValidateState(State{Extras: exact}) {
		t.Fatalf("extras of exactly MaxExtrasBytes (%d) must be accepted", MaxExtrasBytes)
	}

	over := atLength(MaxExtrasBytes + 1)
	if b, _ := json.Marshal(over); len(b) != MaxExtrasBytes+1 {
		t.Fatalf("fixture is wrong: len=%d, wanted exactly %d", len(b), MaxExtrasBytes+1)
	}
	if ValidateState(State{Extras: over}) {
		t.Fatalf("extras of MaxExtrasBytes+1 (%d) must be rejected", MaxExtrasBytes+1)
	}
}

// The pooled sizer is shared across goroutines by construction: the relay
// validates every client's state on that client's own read goroutine, so this
// runs concurrently at exactly the room's message rate. Guards against the
// buffer being reused mid-encode, which -race reports and a serial test cannot.
func TestExtrasSizingIsConcurrencySafe(t *testing.T) {
	small := map[string]any{"k": "v"}
	big := map[string]any{"k": strings.Repeat("b", MaxExtrasBytes)}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				if !ValidateState(State{Extras: small}) {
					t.Errorf("small extras rejected under concurrency")
					return
				}
				if ValidateState(State{Extras: big}) {
					t.Errorf("oversized extras accepted under concurrency")
					return
				}
			}
		}(i)
	}
	wg.Wait()
}
