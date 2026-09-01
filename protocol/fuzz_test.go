package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

// The relay is a listening socket that strangers connect to, and every byte
// it parses is attacker-controlled. limits_test.go checks the boundaries
// someone thought of; these targets check the ones nobody did.
//
// Run a longer campaign than the seed corpus with:
//
//	go test ./protocol -run=Fuzz -fuzz=FuzzValidateStateIsStableAcrossTheWire -fuzztime=60s
//
// CI runs a short campaign of each on every push (.github/workflows/ci.yml).

// FuzzEnvelopeUnmarshalNeverPanics feeds arbitrary bytes to the outermost
// decode every connection performs before it knows anything about the
// message. Decoding must fail cleanly, never panic — the relay treats a
// malformed line as "ignore and keep going", which is only safe if the
// decode itself can't take the process down.
func FuzzEnvelopeUnmarshalNeverPanics(f *testing.F) {
	f.Add([]byte(`{"type":"state","payload":{}}`))
	f.Add([]byte(`{"type":"hello","payload":null}`))
	f.Add([]byte(`{"type":`))
	f.Add([]byte(`{"payload":[1,2,3]}`))
	f.Add([]byte(``))

	f.Fuzz(func(t *testing.T, data []byte) {
		var env Envelope
		if err := json.Unmarshal(data, &env); err != nil {
			return
		}
		// A successful decode must leave Payload either absent or itself
		// valid JSON, since every call site immediately unmarshals it again.
		if len(env.Payload) > 0 && !json.Valid(env.Payload) {
			t.Fatalf("decoded envelope carries invalid JSON payload %q", env.Payload)
		}
	})
}

// FuzzValidateStateIsStableAcrossTheWire is the property that actually
// matters for relay safety, and it is not a restatement of ValidateState's
// own checks.
//
// The relay validates an inbound State, then re-marshals it to forward to
// every other peer, where each receiving core validates it again. If any
// State could pass validation and then fail it after a marshal/unmarshal
// round trip, a peer could push a state through the relay's gate that its
// neighbours' cores then reject — or worse, one that arrives holding a value
// the gate was supposed to have stopped. The forwarding path must not be
// able to change a state's validity in either direction.
func FuzzValidateStateIsStableAcrossTheWire(f *testing.F) {
	f.Add([]byte(`{"player_id":"p1","position":[1,2],"area_id":"a","anim":"walk"}`))
	f.Add([]byte(`{"position":[1e308]}`))
	f.Add([]byte(`{"position":[1e7,-1e7]}`))
	f.Add([]byte(`{"position":[0.1,0.2,0.30000000000000004]}`))
	f.Add([]byte(`{"orientation":{"x":1},"extras":{"k":"v"}}`))
	f.Add([]byte(`{"position":[]}`))

	f.Fuzz(func(t *testing.T, data []byte) {
		var st State
		if err := json.Unmarshal(data, &st); err != nil {
			return
		}

		before := ValidateState(st)

		// Exactly what the relay does to forward an accepted state on.
		wire, err := json.Marshal(st)
		if err != nil {
			if before {
				t.Fatalf("state passed validation but cannot be forwarded: %v", err)
			}
			return
		}
		var got State
		if err := json.Unmarshal(wire, &got); err != nil {
			t.Fatalf("re-decoding our own marshaled state failed: %v (wire=%q)", err, wire)
		}

		if after := ValidateState(got); after != before {
			t.Fatalf("validity changed across a forward: before=%v after=%v (wire=%q)",
				before, after, wire)
		}
	})
}

// FuzzValidPositionsSurviveNarrowingToFloat32 guards the specific hazard
// MaxPositionComponent exists for: both shipped 3D adapters narrow position
// components to float32 (TEVI's Unity Transform, Pseudoregalia's engine
// calls), and a value that is finite as a float64 but becomes ±Inf as a
// float32 would reach a real game's renderer. IsValidPosition's bound is
// supposed to make that unreachable — this proves no accepted input escapes
// it, rather than trusting that 1e7 was picked correctly.
func FuzzValidPositionsSurviveNarrowingToFloat32(f *testing.F) {
	f.Add([]byte(`[1,2,3]`))
	f.Add([]byte(`[1e7]`))
	f.Add([]byte(`[3.5e38]`))
	f.Add([]byte(`[-1e308,1e308]`))

	f.Fuzz(func(t *testing.T, data []byte) {
		var pos []float64
		if err := json.Unmarshal(data, &pos); err != nil {
			return
		}
		if !IsValidPosition(pos) {
			return
		}
		for i, v := range pos {
			narrowed := float32(v)
			if math32IsInf(narrowed) || math32IsNaN(narrowed) {
				t.Fatalf("position[%d]=%v passed IsValidPosition but narrows to %v as float32",
					i, v, narrowed)
			}
		}
	})
}

// math32IsInf/math32IsNaN avoid a float32->float64 widening round trip,
// which would hide exactly the overflow being tested.
func math32IsInf(f float32) bool { return f > 3.4e38 || f < -3.4e38 }
func math32IsNaN(f float32) bool { return f != f }

// FuzzValidateEventIsStableAcrossTheWire is ValidateEvent's counterpart to
// the state-plane target above: the event plane's payload is fully opaque, so
// the only thing standing between a stranger's bytes and the relay's forward
// path is this one bounds check. A payload that validates must still validate
// after a round trip through JSON, or the relay and the receiving core could
// reach different conclusions about the same message.
func FuzzValidateEventIsStableAcrossTheWire(f *testing.F) {
	f.Add("", "", []byte(`{"a":1}`))
	f.Add("p2", "corr-1", []byte(`null`))
	f.Add("p2", "", []byte(``))

	f.Fuzz(func(t *testing.T, to, corrID string, payload []byte) {
		ev := Event{To: to, CorrID: corrID}
		if json.Valid(payload) {
			ev.Payload = json.RawMessage(payload)
		}
		if !ValidateEvent(ev) {
			return
		}
		b, err := json.Marshal(ev)
		if err != nil {
			t.Fatalf("a valid event failed to marshal: %v", err)
		}
		var back Event
		if err := json.Unmarshal(b, &back); err != nil {
			t.Fatalf("a valid event failed to round trip: %v", err)
		}
		if !ValidateEvent(back) {
			t.Fatalf("event validated before the wire and not after: %+v -> %+v", ev, back)
		}
	})
}

// FuzzValidateLeaseAndEscrowNeverPanic covers the two arbitration planes'
// bounds checks. Neither may panic on any input: the relay calls them on
// bytes a stranger chose, before the request reaches any of its own state.
func FuzzValidateLeaseAndEscrowNeverPanic(f *testing.F) {
	f.Add("claim", "route103:candy", 0, "open", "trade-1", "p2", []byte(`{"x":1}`))
	f.Add("", "", -1, "", "", "", []byte(``))

	f.Fuzz(func(t *testing.T, leaseOp, key string, ttl int, escrowOp, id, with string, blob []byte) {
		ValidateLease(Lease{Op: LeaseOp(leaseOp), Key: key, TTLMs: ttl})
		// Whatever the request said, a resolved TTL must always land inside
		// the honoured range — a negative or absurd value is clamped, never
		// passed through into a timer.
		if d := ClampLeaseTTL(ttl); d < MinLeaseTTL || d > MaxLeaseTTL {
			t.Fatalf("ClampLeaseTTL(%d) = %v, outside [%v, %v]", ttl, d, MinLeaseTTL, MaxLeaseTTL)
		}
		e := Escrow{Op: EscrowOp(escrowOp), ID: id, With: with}
		if json.Valid(blob) {
			e.Blob = json.RawMessage(blob)
		}
		ValidateEscrow(e)
	})
}

// FuzzNormalizeFeaturesIsIdempotent guards the property the relay's room
// stickiness depends on: normalizing twice must equal normalizing once, or
// two clients advertising the same capabilities could compare unequal and be
// refused a shared room for no reason.
func FuzzNormalizeFeaturesIsIdempotent(f *testing.F) {
	f.Add("lease.v1,event.v1")
	f.Add(" a , a ,,b")
	f.Add("")

	f.Fuzz(func(t *testing.T, joined string) {
		in := strings.Split(joined, ",")
		once := NormalizeFeatures(in)
		twice := NormalizeFeatures(once)
		if FeatureSetKey(once) != FeatureSetKey(twice) {
			t.Fatalf("NormalizeFeatures is not idempotent: %q -> %v -> %v", joined, once, twice)
		}
	})
}

// FuzzValidateWorldIsStableAcrossTheWire is FuzzValidateEventIsStableAcrossTheWire
// applied to the world plane, and the Authority field is the reason it exists.
//
// A non-UTF-8 string round-trips through JSON as a DIFFERENT string, because
// encoding/json replaces each invalid byte with U+FFFD. For an authority that
// is uniquely nasty: the relay compares it for equality against a lease key, so
// a client whose own validation passed would have every single write silently
// denied, with nothing anywhere able to explain why. The replacement also
// expands, so the length check can pass before marshaling and fail after.
func FuzzValidateWorldIsStableAcrossTheWire(f *testing.F) {
	f.Add("set", "sim", "e0", []byte(`{"gen":1}`))
	f.Add("drop", "sim", "e0", []byte(``))
	f.Add("set", "\xff\xfe", "e0", []byte(`null`))

	f.Fuzz(func(t *testing.T, op, authority, key string, blob []byte) {
		w := World{Op: WorldOp(op), Authority: authority, Key: key}
		if json.Valid(blob) {
			w.Blob = json.RawMessage(blob)
		}
		if !ValidateWorld(w) {
			return
		}
		b, err := json.Marshal(w)
		if err != nil {
			t.Fatalf("a valid world write failed to marshal: %v", err)
		}
		var back World
		if err := json.Unmarshal(b, &back); err != nil {
			t.Fatalf("a valid world write failed to round trip: %v", err)
		}
		if !ValidateWorld(back) {
			t.Fatalf("world write validated before the wire and not after: %+v -> %+v", w, back)
		}
		if back.Authority != w.Authority || back.Key != w.Key {
			t.Fatalf("an opaque identifier changed across the wire: %q/%q -> %q/%q "+
				"-- equality against the lease key it names would silently stop working",
				w.Authority, w.Key, back.Authority, back.Key)
		}
	})
}

// FuzzExtrasSizingMatchesMarshal pins the one thing extrasWithinLimit is
// allowed to be: a cheaper way to compute EXACTLY the number json.Marshal would
// have produced. It replaced a literal json.Marshal whose only use was len() on
// the result, so a disagreement here would not be a slow path — it would be a
// moved validation boundary, a state one enforcement point accepts and the
// other rejects, which is the drift protocol/limits.go exists to prevent.
//
// Worth fuzzing rather than table-testing because the hazard lives in encoding,
// not in logic: HTML escaping, U+2028/9, invalid UTF-8 replaced by U+FFFD, and
// float formatting all change the byte count without changing the value.
func FuzzExtrasSizingMatchesMarshal(f *testing.F) {
	f.Add([]byte(`{"k":"v"}`))
	f.Add([]byte(`{"a":"<&>"}`))
	f.Add([]byte(`{"gender":"m","gfx":1,"sanim":0,"pspeed":1}`))
	f.Add([]byte(`{"f":0.30000000000000004,"big":1e308,"neg":-0}`))
	f.Add([]byte(`{"u":"\u2028\u2029"}`))
	f.Add([]byte(`{"nested":{"deep":[1,2,{"x":null}]}}`))
	f.Add([]byte(`{}`))

	f.Fuzz(func(t *testing.T, data []byte) {
		var extras map[string]any
		if err := json.Unmarshal(data, &extras); err != nil {
			return
		}
		marshaled, err := json.Marshal(extras)
		if err != nil {
			return
		}
		want := len(marshaled) <= MaxExtrasBytes
		if len(extras) == 0 {
			// An empty or absent map is not serialized at all by the caller's
			// own short-circuit, so it is within the limit by definition.
			want = true
		}
		if got := extrasWithinLimit(extras); got != want {
			t.Fatalf("extrasWithinLimit=%v but json.Marshal is %d bytes (limit %d): %q",
				got, len(marshaled), MaxExtrasBytes, marshaled)
		}

		// The property the cheap path RESTS on, checked separately because the
		// check above would still pass if the bound were wrong in a way that
		// happened not to straddle the limit for this input. A bound that ever
		// came in UNDER the true length would accept an oversized extras
		// without ever consulting the encoder -- silently raising
		// MaxExtrasBytes for exactly the values it mis-measured.
		if bound, ok := extrasLengthBound(extras); ok && bound < len(marshaled) {
			t.Fatalf("extrasLengthBound under-estimated: bound=%d actual=%d for %q",
				bound, len(marshaled), marshaled)
		}
	})
}

// FuzzClampRatesAlwaysLandInRange fuzzes the two rate resolvers, which sit on
// the boundary where a relay's advertised send_hz and a peer's requested
// receive cap enter this process. Added 2026-09-01 with the DefaultSendHz
// 20 -> 15 change, on the user's principle that a value crossing the wire
// deserves the same engine as every other one: "I want the fuzzer to actually
// test/randomize everything".
//
// These are the properties every caller already assumes and none of them
// re-check -- core trusts ClampSendHz's answer to drive its send loop, and the
// relay trusts it to size a flood cap. A resolver that returned an
// out-of-range value would put a client into a send rate nothing enforces.
func FuzzClampRatesAlwaysLandInRange(f *testing.F) {
	for _, hz := range []int{0, -1, 1, MinSendHz, DefaultSendHz, 20, MaxSendHz, MaxSendHz + 1, 1 << 20, -(1 << 20)} {
		f.Add(hz)
	}

	f.Fuzz(func(t *testing.T, hz int) {
		send := ClampSendHz(hz)
		if send < MinSendHz || send > MaxSendHz {
			t.Fatalf("ClampSendHz(%d) = %d, outside [%d, %d] -- a send rate that escapes the range is one nothing enforces", hz, send, MinSendHz, MaxSendHz)
		}
		// Zero and negative mean "unspecified", which is the only case allowed
		// to invent a number rather than pass one through.
		if hz <= 0 && send != DefaultSendHz {
			t.Fatalf("ClampSendHz(%d) = %d, want DefaultSendHz (%d): unspecified must resolve to the default", hz, send, DefaultSendHz)
		}
		// An already-legal rate must survive untouched, or a relay's honest
		// configuration silently becomes something else.
		if hz >= MinSendHz && hz <= MaxSendHz && send != hz {
			t.Fatalf("ClampSendHz(%d) = %d: an in-range rate must pass through unchanged", hz, send)
		}
		// Idempotent: clamping a clamped value is a no-op, which is what makes
		// it safe to apply at both ends of the wire.
		if again := ClampSendHz(send); again != send {
			t.Fatalf("ClampSendHz is not idempotent: %d -> %d -> %d", hz, send, again)
		}

		recv := ClampReceiveHz(hz)
		// Zero is "uncapped" here rather than "use the default" -- the one way
		// the two resolvers deliberately differ.
		if recv != 0 && (recv < MinSendHz || recv > MaxSendHz) {
			t.Fatalf("ClampReceiveHz(%d) = %d, neither 0 (uncapped) nor inside [%d, %d]", hz, recv, MinSendHz, MaxSendHz)
		}
		if hz <= 0 && recv != 0 {
			t.Fatalf("ClampReceiveHz(%d) = %d, want 0: an unset cap means uncapped, never a default rate", hz, recv)
		}
		if again := ClampReceiveHz(recv); again != recv {
			t.Fatalf("ClampReceiveHz is not idempotent: %d -> %d -> %d", hz, recv, again)
		}
	})
}
