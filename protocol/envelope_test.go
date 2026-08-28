package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

// AppendEnvelope's whole justification is that it produces bytes identical to
// json.Marshal. That is a claim about encoding/json's behaviour, not about this
// package's, so it is checked against the real thing rather than against a
// hand-written expectation -- an expectation could encode the same
// misunderstanding twice and agree with itself.
func TestAppendEnvelopeMatchesMarshal(t *testing.T) {
	payloads := map[string]any{
		"empty object":      map[string]any{},
		"typical state":     map[string]any{"area_id": "map:1:2", "position": []float64{1, 2}},
		"html sensitive":    map[string]any{"s": "<script>&</script>"},
		"line separators":   map[string]any{"s": "\u2028\u2029"},
		"quotes and slash":  map[string]any{"s": `he said "hi\there"`},
		"control chars":     map[string]any{"s": "a\nb\tc\rd\x00e"},
		"unicode":           map[string]any{"s": "日本語 émoji 🎮"},
		"nested":            map[string]any{"a": map[string]any{"b": []any{1, "x", nil, true}}},
		"numbers":           map[string]any{"f": 0.30000000000000004, "big": 1e308, "neg": -0.0},
		"null value":        map[string]any{"n": nil},
		"empty string key":  map[string]any{"": "v"},
		"key needs escapes": map[string]any{"a<b>&c": "v"},
	}

	// Every type the relay actually puts on the wire, so this cannot pass while
	// silently skipping the one that matters.
	types := []MessageType{
		TypeState, TypeJoin, TypeLeave, TypeHello, TypeWelcome, TypeReject,
		TypePing, TypePong, TypeEvent, TypeTransports,
	}

	for name, payload := range payloads {
		raw, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("%s: fixture will not marshal: %v", name, err)
		}
		for _, mt := range types {
			want, err := json.Marshal(Envelope{Type: mt, Payload: raw})
			if err != nil {
				t.Fatalf("%s/%s: marshal envelope: %v", name, mt, err)
			}
			got := AppendEnvelope(nil, mt, raw)
			if string(got) != string(want) {
				t.Fatalf("%s/%s:\n got %s\nwant %s", name, mt, got, want)
			}
		}
	}
}

// The single case where AppendEnvelope deliberately does NOT match Marshal,
// recorded here because "byte-identical to json.Marshal" is the claim the whole
// function rests on and an unstated exception to it would be a trap.
//
// json.Marshal REFUSES an empty json.RawMessage outright -- "unexpected end of
// JSON input" -- so the relay's own envelope() could only ever return an error
// its callers turn into a dropped message and a BUG log. AppendEnvelope has no
// error to return, so it emits null: still valid JSON, still parseable by the
// peer, and strictly safer than the alternative of writing a malformed line.
//
// Unreachable in practice from either construction path (envelope() marshals a
// real value; nothing hands this an empty payload), which is exactly why it is
// pinned -- an unreachable case is one nobody re-checks after changing it.
func TestAppendEnvelopeEmptyPayloadIsNullWhereMarshalRefuses(t *testing.T) {
	const want = `{"type":"state","payload":null}`

	// A NIL payload is not the divergence: RawMessage.MarshalJSON special-cases
	// nil to null, so both agree here.
	if b, err := json.Marshal(Envelope{Type: TypeState, Payload: nil}); err != nil || string(b) != want {
		t.Fatalf("marshal of a nil payload: %s err=%v, want %s", b, err, want)
	}
	if got := AppendEnvelope(nil, TypeState, nil); string(got) != want {
		t.Fatalf("nil payload: got %s, want %s", got, want)
	}

	// A non-nil EMPTY payload is: Marshal refuses it, and we emit null.
	if _, err := json.Marshal(Envelope{Type: TypeState, Payload: []byte{}}); err == nil {
		t.Fatal("json.Marshal now accepts an empty non-nil RawMessage; " +
			"AppendEnvelope's documented divergence needs revisiting")
	}
	got := AppendEnvelope(nil, TypeState, []byte{})
	if string(got) != want {
		t.Fatalf("empty payload: got %s, want %s", got, want)
	}
	if !json.Valid(got) {
		t.Fatalf("produced invalid JSON: %s", got)
	}
}

// Appending to a non-empty destination must extend it rather than overwrite,
// since the point of taking a dst at all is reuse of an existing buffer.
func TestAppendEnvelopeExtendsDestination(t *testing.T) {
	prefix := []byte("keep me")
	got := AppendEnvelope(prefix, TypeState, []byte(`{"a":1}`))
	if !strings.HasPrefix(string(got), "keep me{") {
		t.Fatalf("destination was not extended: %s", got)
	}
}

// A message type this build does not know is still forwarded by the relay's
// generic paths, so the escaping has to be real rather than assumed-ASCII.
func TestAppendEnvelopeEscapesAnExoticType(t *testing.T) {
	exotic := MessageType("weird\"<type>\n\u2028")
	want, err := json.Marshal(Envelope{Type: exotic, Payload: []byte(`1`)})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if got := AppendEnvelope(nil, exotic, []byte(`1`)); string(got) != string(want) {
		t.Fatalf("\n got %s\nwant %s", got, want)
	}
}
