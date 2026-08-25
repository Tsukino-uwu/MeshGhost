package cfg

import (
	"bytes"
	"encoding/json"
	"log"
	"strings"
	"testing"
)

// captureLog runs fn with the standard logger redirected, and returns what it
// wrote. Every function in this package reports to the user through log, so the
// log line IS the behaviour under test -- these are user-facing messages a
// confused non-developer reads while their config is half-applied.
func captureLog(t *testing.T, fn func()) string {
	t.Helper()
	var buf bytes.Buffer
	oldOut, oldFlags := log.Writer(), log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	defer func() { log.SetOutput(oldOut); log.SetFlags(oldFlags) }()
	fn()
	return buf.String()
}

func TestStripBOMRemovesUTF8BOM(t *testing.T) {
	want := `{"a":1}`
	in := append([]byte{0xEF, 0xBB, 0xBF}, want...)
	got := captureStrip(t, in)
	if string(got) != want {
		t.Fatalf("BOM not stripped: got %q, want %q", got, want)
	}
}

func TestStripBOMLeavesCleanInputAlone(t *testing.T) {
	want := `{"a":1}`
	got := captureStrip(t, []byte(want))
	if string(got) != want {
		t.Fatalf("clean input altered: got %q, want %q", got, want)
	}
}

// A UTF-16 file cannot be salvaged, so it must return nil AND say what to do --
// the whole point is that the raw encoding/json error names none of that.
func TestStripBOMRefusesUTF16AndSaysHowToFix(t *testing.T) {
	for name, bom := range map[string][]byte{
		"little-endian": {0xFF, 0xFE},
		"big-endian":    {0xFE, 0xFF},
	} {
		t.Run(name, func(t *testing.T) {
			var got []byte
			out := captureLog(t, func() {
				got = StripBOM(append(bom, '{', '}'), "config.json", "meshghost")
			})
			if got != nil {
				t.Fatalf("UTF-16 input should be refused, got %q", got)
			}
			if !strings.Contains(out, "UTF-16") || !strings.Contains(out, "re-save it as UTF-8") {
				t.Fatalf("warning does not name the fix: %q", out)
			}
			if !strings.Contains(out, "meshghost") {
				t.Fatalf("warning does not name the program: %q", out)
			}
		})
	}
}

func captureStrip(t *testing.T, in []byte) []byte {
	t.Helper()
	var got []byte
	captureLog(t, func() { got = StripBOM(in, "config.json", "meshghost") })
	return got
}

// A syntax error is fatal to the whole file and must say so: the rest genuinely
// cannot be trusted to be what the user meant.
func TestApplyDespiteBadValueRefusesSyntaxError(t *testing.T) {
	var v struct {
		A int `json:"a"`
	}
	err := json.Unmarshal([]byte(`{"a": 1,,}`), &v)
	if err == nil {
		t.Fatal("expected a syntax error from the malformed fixture")
	}
	var ok bool
	out := captureLog(t, func() { ok = ApplyDespiteBadValue(err, "config.json", "meshghost") })
	if ok {
		t.Fatal("a syntax error must not be survivable -- the rest of the file is untrustworthy")
	}
	if !strings.Contains(out, "IGNORED") {
		t.Fatalf("whole-file warning missing: %q", out)
	}
}

// The 2026-08-16 bug itself: one mistyped value used to discard every other
// setting. A type error must be survivable and must say only that ONE key is
// being dropped.
func TestApplyDespiteBadValueSurvivesTypeError(t *testing.T) {
	var v struct {
		ShowConsole bool   `json:"show_console"`
		RoomCode    string `json:"room_code"`
	}
	err := json.Unmarshal([]byte(`{"show_console": "true", "room_code": "hunter2"}`), &v)
	if err == nil {
		t.Fatal("expected a type error from the quoted bool")
	}
	if v.RoomCode != "hunter2" {
		t.Fatalf("every other setting must still decode; room_code = %q", v.RoomCode)
	}
	var ok bool
	out := captureLog(t, func() { ok = ApplyDespiteBadValue(err, "config.json", "meshghost") })
	if !ok {
		t.Fatal("a type error must be survivable -- that was the whole bug")
	}
	if !strings.Contains(out, "show_console") {
		t.Fatalf("warning does not name the offending key: %q", out)
	}
	if !strings.Contains(out, "everything else in the file still applies") {
		t.Fatalf("warning does not reassure about the other settings: %q", out)
	}
}

// The regression this package's extraction actually fixes. Both mains used to
// hardcode ONE example -- the client always printed `true`, the relay always `8`
// -- so each printed the wrong kind of value whenever the mistyped key happened
// to be of the other type, which is exactly when someone is reading the message.
// The example is now derived from the type.
func TestApplyDespiteBadValueExampleMatchesTheType(t *testing.T) {
	cases := []struct {
		name, doc, wantExample, wantNotExample string
	}{
		{"bool key", `{"show_console": "true"}`, `"show_console": true`, `"show_console": 8`},
		{"int key", `{"send_hz": "20"}`, `"send_hz": 8`, `"send_hz": true`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var v struct {
				ShowConsole bool `json:"show_console"`
				SendHz      int  `json:"send_hz"`
			}
			err := json.Unmarshal([]byte(tc.doc), &v)
			if err == nil {
				t.Fatal("expected a type error")
			}
			out := captureLog(t, func() { ApplyDespiteBadValue(err, "config.json", "meshghost") })
			if !strings.Contains(out, tc.wantExample) {
				t.Errorf("example should match the field's type.\n got: %q\nwant it to contain: %q", out, tc.wantExample)
			}
			if strings.Contains(out, tc.wantNotExample) {
				t.Errorf("example is for the wrong type.\n got: %q\nmust not contain: %q", out, tc.wantNotExample)
			}
		})
	}
}

// A string field given a number: quotes are the FIX here, not the problem, so the
// "quotes make a value text" parenthetical would tell the user to do the opposite
// of what they need.
func TestApplyDespiteBadValueDoesNotBlameQuotesOnAStringField(t *testing.T) {
	var v struct {
		Name string `json:"name"`
	}
	err := json.Unmarshal([]byte(`{"name": 7}`), &v)
	if err == nil {
		t.Fatal("expected a type error")
	}
	var ok bool
	out := captureLog(t, func() { ok = ApplyDespiteBadValue(err, "config.json", "meshghost") })
	if !ok {
		t.Fatal("a type error must be survivable")
	}
	if strings.Contains(out, "Quotes make a value text") {
		t.Fatalf("must not tell a user to remove the quotes a string field needs: %q", out)
	}
	if !strings.Contains(out, "needs text in quotes") {
		t.Fatalf("should say the field needs quoted text: %q", out)
	}
}
