package protocol

import (
	"encoding/json"
	"testing"
)

// The relay is a listening socket that strangers connect to, and every byte
// it parses is attacker-controlled. limits_test.go checks the boundaries
// someone thought of; these targets check the ones nobody did.
//
// Run a longer campaign than the seed corpus with:
//
//	go test ./internal/protocol -run=Fuzz -fuzz=FuzzValidateStateIsStableAcrossTheWire -fuzztime=60s
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
