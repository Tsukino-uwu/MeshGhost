package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

// Every byte the relay parses is attacker-controlled: limits_test.go checks the boundaries someone thought of, and
// these targets look for the ones nobody did.

// FuzzEnvelopeUnmarshalNeverPanics fuzzes the outermost decode of every line. The relay ignores a malformed line and
// keeps going, which is safe only if the decode cannot take the process down.
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
		// Every call site unmarshals Payload again.
		if len(env.Payload) > 0 && !json.Valid(env.Payload) {
			t.Fatalf("decoded envelope carries invalid JSON payload %q", env.Payload)
		}
	})
}

// FuzzValidateStateIsStableAcrossTheWire: the relay validates a State, re-marshals it, and each receiving core
// validates it again, so a forward must not change a state's validity in either direction.
func FuzzValidateStateIsStableAcrossTheWire(f *testing.F) {
	f.Add([]byte(`{"player_id":"p1","position":[1,2],"area_id":"a","anim":"walk"}`))
	f.Add([]byte(`{"position":[1e308]}`))
	f.Add([]byte(`{"position":[1e7,-1e7]}`))
	f.Add([]byte(`{"position":[0.1,0.2,0.30000000000000004]}`))
	f.Add([]byte(`{"orientation":{"x":1},"extras":{"k":"v"}}`))
	f.Add([]byte(`{"position":[1,2],"prev":{"seq":1,"timestamp":5,"position":[0,2],"extras":{"k":null},"orientation":null}}`))
	f.Add([]byte(`{"position":[1,2],"prev":{"position":[1e308]}}`))
	f.Add([]byte(`{"position":[]}`))

	f.Fuzz(func(t *testing.T, data []byte) {
		var st State
		if err := json.Unmarshal(data, &st); err != nil {
			return
		}

		before := ValidateState(st)

		// What the relay does to forward an accepted state.
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

// FuzzValidPositionsSurviveNarrowingToFloat32 guards what MaxPositionComponent is for: the 3D adapters narrow
// position components to float32, and a value finite as a float64 but infinite as a float32 would reach a renderer.
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

func math32IsInf(f float32) bool { return f > 3.4e38 || f < -3.4e38 }
func math32IsNaN(f float32) bool { return f != f }

// FuzzValidateEventIsStableAcrossTheWire: an opaque payload meets only this bounds check before the relay forwards
// it, so a valid event must stay valid after a JSON round trip, or relay and core could disagree about it.
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

// FuzzValidateLeaseAndEscrowNeverPanic: the relay calls both checks on a stranger's bytes before touching its own
// state.
func FuzzValidateLeaseAndEscrowNeverPanic(f *testing.F) {
	f.Add("claim", "route103:candy", 0, "open", "trade-1", "p2", []byte(`{"x":1}`))
	f.Add("", "", -1, "", "", "", []byte(``))

	f.Fuzz(func(t *testing.T, leaseOp, key string, ttl int, escrowOp, id, with string, blob []byte) {
		ValidateLease(Lease{Op: LeaseOp(leaseOp), Key: key, TTLMs: ttl})
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

// FuzzNormalizeFeaturesIsIdempotent: room stickiness depends on it, or two clients advertising the same
// capabilities could compare unequal and be refused a shared room.
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

// FuzzValidateWorldIsStableAcrossTheWire exists for Authority: invalid UTF-8 round-trips as a different, longer
// string, and the relay compares the authority to a lease key, so every write would be silently denied.
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

// FuzzExtrasSizingMatchesMarshal: extrasWithinLimit must give json.Marshal's verdict exactly, or the validation
// boundary moves and one enforcement point accepts a state the other rejects.
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
			// The caller short-circuits an empty map, so it is within the limit by definition.
			want = true
		}
		if got := extrasWithinLimit(extras); got != want {
			t.Fatalf("extrasWithinLimit=%v but json.Marshal is %d bytes (limit %d): %q",
				got, len(marshaled), MaxExtrasBytes, marshaled)
		}

		// Checked apart from the verdict: a bound under the true length would accept an oversized extras without
		// consulting the encoder, even where this input does not straddle the limit.
		if bound, ok := extrasLengthBound(extras); ok && bound < len(marshaled) {
			t.Fatalf("extrasLengthBound under-estimated: bound=%d actual=%d for %q",
				bound, len(marshaled), marshaled)
		}
	})
}

// FuzzClampRatesAlwaysLandInRange: the core drives its send loop and the relay sizes a flood cap from these answers,
// and neither re-checks the range.
func FuzzClampRatesAlwaysLandInRange(f *testing.F) {
	for _, hz := range []int{0, -1, 1, MinSendHz, DefaultSendHz, 20, MaxSendHz, MaxSendHz + 1, 1 << 20, -(1 << 20)} {
		f.Add(hz)
	}

	f.Fuzz(func(t *testing.T, hz int) {
		send := ClampSendHz(hz)
		if send < MinSendHz || send > MaxSendHz {
			t.Fatalf("ClampSendHz(%d) = %d, outside [%d, %d] -- a send rate that escapes the range is one nothing enforces", hz, send, MinSendHz, MaxSendHz)
		}
		if hz <= 0 && send != DefaultSendHz {
			t.Fatalf("ClampSendHz(%d) = %d, want DefaultSendHz (%d): unspecified must resolve to the default", hz, send, DefaultSendHz)
		}
		if hz >= MinSendHz && hz <= MaxSendHz && send != hz {
			t.Fatalf("ClampSendHz(%d) = %d: an in-range rate must pass through unchanged", hz, send)
		}
		// Idempotence is what makes it safe to apply at both ends of the wire.
		if again := ClampSendHz(send); again != send {
			t.Fatalf("ClampSendHz is not idempotent: %d -> %d -> %d", hz, send, again)
		}

		recv := ClampReceiveHz(hz)
		// Zero is uncapped here, not the default: the one way the two resolvers differ.
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

// FuzzDepthBoundsAgreeAndNeverPanic fuzzes the raw-byte scan against the decoded walk. Orientation is bounded by the
// scan alone, so a scan more permissive than the walk would let a refused shape in through it.
func FuzzDepthBoundsAgreeAndNeverPanic(f *testing.F) {
	f.Add([]byte(`{"a":1}`))
	f.Add([]byte(`[[[[[[[[]]]]]]]]`))
	f.Add([]byte(`{"a":"{{{{{{{{"}`)) // braces inside a string are not nesting
	f.Add([]byte(strings.Repeat("[", 200) + strings.Repeat("]", 200)))
	f.Add([]byte(`{"a":[{"b":[{"c":1}]}]}`))
	f.Add([]byte(`"\"[[[["`))
	f.Add([]byte(``))

	f.Fuzz(func(t *testing.T, b []byte) {
		scanOK := rawJSONDepthWithinLimit(b)

		// Invalid JSON is out of scope: the scan is not a validator, and a malformed value is refused elsewhere.
		var v any
		if err := json.Unmarshal(b, &v); err != nil {
			return
		}
		walkOK := jsonDepthWithinLimit(v, 1)
		if scanOK != walkOK {
			t.Fatalf("the two depth bounds disagree on %q: byte scan says within=%v, decoded walk says within=%v", b, scanOK, walkOK)
		}

		// The verdict must be the one ValidateState acts on, through the field it never decodes.
		if len(b) <= MaxOrientationBytes {
			st := State{Position: []float64{1, 2}, Orientation: json.RawMessage(b)}
			if got := ValidateState(st); got && !scanOK {
				t.Fatalf("ValidateState accepted an orientation the depth bound refuses: %q", b)
			}
		}
	})
}
