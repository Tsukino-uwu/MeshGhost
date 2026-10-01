package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestAppendEnvelopeMatchesMarshal checks against encoding/json itself, since a hand-written expectation could
// share the misunderstanding it is meant to catch.
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

// TestAppendEnvelopeEmptyPayloadIsNullWhereMarshalRefuses pins the one case where AppendEnvelope does not match
// Marshal: it has no error to return, so it emits null. Unreachable in practice, which is why it is pinned.
func TestAppendEnvelopeEmptyPayloadIsNullWhereMarshalRefuses(t *testing.T) {
	const want = `{"type":"state","payload":null}`

	// A nil payload is not the divergence: RawMessage.MarshalJSON turns nil into null.
	if b, err := json.Marshal(Envelope{Type: TypeState, Payload: nil}); err != nil || string(b) != want {
		t.Fatalf("marshal of a nil payload: %s err=%v, want %s", b, err, want)
	}
	if got := AppendEnvelope(nil, TypeState, nil); string(got) != want {
		t.Fatalf("nil payload: got %s, want %s", got, want)
	}

	// A non-nil empty payload is.
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

func TestAppendEnvelopeExtendsDestination(t *testing.T) {
	prefix := []byte("keep me")
	got := AppendEnvelope(prefix, TypeState, []byte(`{"a":1}`))
	if !strings.HasPrefix(string(got), "keep me{") {
		t.Fatalf("destination was not extended: %s", got)
	}
}

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
