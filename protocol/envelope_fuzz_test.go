package protocol

import (
	"encoding/json"
	"testing"
)

// FuzzAppendEnvelopeMatchesMarshal is the proof behind AppendEnvelope's
// doc comment, and it is worth fuzzing rather than table-testing because the
// hazard is entirely in ENCODING rather than in logic: HTML escaping,
// U+2028/U+2029, invalid UTF-8 becoming U+FFFD, and compaction of insignificant
// whitespace all change the bytes without changing the value.
//
// The table test that came first already earned its place -- it caught this
// function passing U+2028 through unescaped, which encoding/json does not do.
// This covers the inputs nobody thinks to write down.
//
// Only payloads encoding/json itself produced are compared, which is the
// function's stated precondition: it is a claim about round-tripping our own
// output, not about arbitrary bytes, and feeding it arbitrary bytes would test
// a contract nothing offers.
func FuzzAppendEnvelopeMatchesMarshal(f *testing.F) {
	f.Add("state", []byte(`{"area_id":"a","position":[1,2]}`))
	f.Add("state", []byte(`{"s":"<script>&</script>"}`))
	f.Add("event", []byte(`{"payload":{"nested":[1,null,true]}}`))
	f.Add("join", []byte(`"just a string"`))
	f.Add("welcome", []byte(`123`))
	f.Add("ping", []byte(`null`))
	f.Add("weird\"type", []byte(`{}`))

	f.Fuzz(func(t *testing.T, typ string, payload []byte) {
		// Normalize the payload through encoding/json, which is exactly the
		// precondition AppendEnvelope documents. Anything that will not
		// round-trip is not a payload this function promises anything about.
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

		// Belt and braces: both lines must decode to the SAME envelope, so a
		// shared misunderstanding of the bytes cannot slip through.
		//
		// Compared against Marshal's own round trip rather than against the
		// input, which is a distinction this fuzzer had to teach: a type
		// carrying invalid UTF-8 comes back as U+FFFD from encoding/json too,
		// so asserting the ORIGINAL type survives would demand a guarantee the
		// standard library does not make and this function must not either.
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
