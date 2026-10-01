package protocol

import (
	"encoding/json"
	"testing"
)

// FuzzAppendEnvelopeMatchesMarshal is fuzzed because the hazard is in encoding, not logic: HTML escaping, U+2028/9,
// invalid UTF-8 and whitespace change the bytes without changing the value. Only payloads encoding/json produced are
// compared, which is AppendEnvelope's precondition.
func FuzzAppendEnvelopeMatchesMarshal(f *testing.F) {
	f.Add("state", []byte(`{"area_id":"a","position":[1,2]}`))
	f.Add("state", []byte(`{"s":"<script>&</script>"}`))
	f.Add("event", []byte(`{"payload":{"nested":[1,null,true]}}`))
	f.Add("join", []byte(`"just a string"`))
	f.Add("welcome", []byte(`123`))
	f.Add("ping", []byte(`null`))
	f.Add("weird\"type", []byte(`{}`))

	f.Fuzz(func(t *testing.T, typ string, payload []byte) {
		var v any
		if err := json.Unmarshal(payload, &v); err != nil {
			return
		}
		raw, err := json.Marshal(v)
		if err != nil {
			return
		}

		mt := MessageType(typ)
		want, err := json.Marshal(Envelope{Type: mt, Payload: raw})
		if err != nil {
			t.Fatalf("marshaling an envelope around our own output failed: %v", err)
		}
		got := AppendEnvelope(nil, mt, raw)
		if string(got) != string(want) {
			t.Fatalf("AppendEnvelope diverged from json.Marshal:\n got %q\nwant %q\ntype %q payload %q",
				got, want, typ, raw)
		}

		// Compared with Marshal's own round trip, not the input: a type with invalid UTF-8 comes back changed from
		// encoding/json too.
		var ours, theirs Envelope
		if err := json.Unmarshal(got, &ours); err != nil {
			t.Fatalf("our own line does not decode: %v (%q)", err, got)
		}
		if err := json.Unmarshal(want, &theirs); err != nil {
			t.Fatalf("json.Marshal's line does not decode: %v (%q)", err, want)
		}
		if ours.Type != theirs.Type {
			t.Fatalf("type decoded differently: ours %q, json.Marshal's %q", ours.Type, theirs.Type)
		}
	})
}
