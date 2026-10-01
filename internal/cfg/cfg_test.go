package cfg

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// captureLog runs fn with the standard logger redirected and returns what it wrote: the log line a player reads is the
// behaviour under test.
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

// TestApplyDespiteBadValueSurvivesTypeError: one mistyped value must not discard every other setting.
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
	if !strings.Contains(out, "everything correctly typed still applies") {
		t.Fatalf("warning does not reassure about the other settings: %q", out)
	}
}

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

// TestOverridePrecedence pins the rule the config system rests on: an explicit flag beats the config file, which beats
// the built-in default.
func TestOverridePrecedence(t *testing.T) {
	const (
		builtin  = "default-value"
		fromFile = "file-value"
		fromFlag = "flag-value"
	)

	t.Run("file value applies when the flag was not given", func(t *testing.T) {
		target := builtin
		value := fromFile
		Override(map[string]bool{}, "name", &target, &value)
		if target != fromFile {
			t.Fatalf("target = %q, want %q -- a file value must apply when no flag was typed", target, fromFile)
		}
	})

	t.Run("explicit flag beats the file", func(t *testing.T) {
		target := fromFlag // what flag.Parse already wrote
		value := fromFile
		Override(map[string]bool{"name": true}, "name", &target, &value)
		if target != fromFlag {
			t.Fatalf("target = %q, want %q -- an explicitly typed flag must win over the config file", target, fromFlag)
		}
	})

	t.Run("absent key leaves the target alone", func(t *testing.T) {
		target := builtin
		Override[string](map[string]bool{}, "name", &target, nil)
		if target != builtin {
			t.Fatalf("target = %q, want %q -- a nil value means the key was absent from the file", target, builtin)
		}
	})

	t.Run("a present-but-empty value is applied, not treated as absent", func(t *testing.T) {
		target := builtin
		empty := ""
		Override(map[string]bool{}, "name", &target, &empty)
		if target != "" {
			t.Fatalf("target = %q, want empty -- an explicitly empty file value must apply", target)
		}
	})

	t.Run("another flag being explicit does not block this one", func(t *testing.T) {
		target := builtin
		value := fromFile
		Override(map[string]bool{"room": true}, "name", &target, &value)
		if target != fromFile {
			t.Fatalf("target = %q, want %q -- only THIS flag's own name may block the override", target, fromFile)
		}
	})

	t.Run("works for non-string types", func(t *testing.T) {
		target := 8
		value := 32
		Override(map[string]bool{}, "max-clients", &target, &value)
		if target != 32 {
			t.Fatalf("target = %d, want 32", target)
		}
		Override(map[string]bool{"max-clients": true}, "max-clients", &target, &value)
		if target != 32 {
			t.Fatalf("target = %d, want 32 unchanged", target)
		}
	})
}

func TestOverrideDuration(t *testing.T) {
	t.Run("a valid duration applies", func(t *testing.T) {
		target := 250 * time.Millisecond
		value := "0ms"
		out := captureLog(t, func() {
			OverrideDuration(map[string]bool{}, "interp", &target, &value, "config.json", "meshghost", "interp")
		})
		if target != 0 {
			t.Fatalf("target = %v, want 0", target)
		}
		if out != "" {
			t.Fatalf("a valid duration logged something: %q", out)
		}
	})

	t.Run("an unparseable duration warns and leaves the target alone", func(t *testing.T) {
		target := 250 * time.Millisecond
		value := "quarter of a second"
		out := captureLog(t, func() {
			OverrideDuration(map[string]bool{}, "interp", &target, &value, "config.json", "meshghost", "interp")
		})
		if target != 250*time.Millisecond {
			t.Fatalf("target = %v, want it untouched at 250ms -- one bad duration must not cost the setting around it", target)
		}
		if !strings.Contains(out, "interp") || !strings.Contains(out, "quarter of a second") {
			t.Fatalf("warning does not name the key and the offending value: %q", out)
		}
	})

	t.Run("explicit flag beats the file here too", func(t *testing.T) {
		target := time.Duration(0) // what -interp=0ms already wrote
		value := "250ms"
		OverrideDuration(map[string]bool{"interp": true}, "interp", &target, &value, "config.json", "meshghost", "interp")
		if target != 0 {
			t.Fatalf("target = %v, want 0 -- an explicitly typed flag must win", target)
		}
	})
}

func TestOpenLogFileRotatesOnceAtMaxLogBytes(t *testing.T) {
	dir := t.TempDir()
	name := filepath.Join(dir, "meshghost.log")

	// Exactly MaxLogBytes: the check is `>=`, so the boundary is the case worth pinning.
	if err := os.WriteFile(name, bytes.Repeat([]byte("a"), MaxLogBytes), 0o644); err != nil {
		t.Fatal(err)
	}

	w := OpenLogFile(name, "test")
	if w == nil {
		t.Fatal("OpenLogFile returned nil for a writable folder")
	}
	if _, err := w.Write([]byte("second generation\n")); err != nil {
		t.Fatal(err)
	}
	if c, ok := w.(io.Closer); ok {
		c.Close()
	}

	rotated, err := os.Stat(name + ".1")
	if err != nil {
		t.Fatalf("no .log.1 after rotation: %v", err)
	}
	if rotated.Size() != MaxLogBytes {
		t.Errorf(".log.1 is %d bytes, want the original %d", rotated.Size(), MaxLogBytes)
	}
	fresh, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	if string(fresh) != "second generation\n" {
		t.Errorf("fresh log holds %q, want only what was written after rotation", fresh)
	}
}

func TestOpenLogFileAppendsBelowMaxLogBytes(t *testing.T) {
	dir := t.TempDir()
	name := filepath.Join(dir, "meshghost.log")
	if err := os.WriteFile(name, []byte("first run\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	w := OpenLogFile(name, "test")
	if w == nil {
		t.Fatal("OpenLogFile returned nil for a writable folder")
	}
	if _, err := w.Write([]byte("second run\n")); err != nil {
		t.Fatal(err)
	}
	if c, ok := w.(io.Closer); ok {
		c.Close()
	}
	got, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "first run\nsecond run\n" {
		t.Errorf("log holds %q, want both runs -- it truncated instead of appending", got)
	}
	if _, err := os.Stat(name + ".1"); !os.IsNotExist(err) {
		t.Error("rotated a log that was under MaxLogBytes")
	}
}

// TestASecondMistypedValueIsNotPromisedToStillApply: encoding/json names only the first mistyped value but skips them
// all, so the message must not promise the rest of the file applied.
func TestASecondMistypedValueIsNotPromisedToStillApply(t *testing.T) {
	var v struct {
		ShowConsole bool   `json:"show_console"`
		SendHz      int    `json:"send_hz"`
		RoomCode    string `json:"room_code"`
	}
	err := json.Unmarshal([]byte(`{"show_console": "true", "send_hz": "20", "room_code": "hunter2"}`), &v)
	if err == nil {
		t.Fatal("expected a type error from the quoted bool")
	}
	if v.SendHz != 0 {
		t.Fatalf("fixture no longer demonstrates the problem: send_hz decoded as %d, want it silently skipped", v.SendHz)
	}
	if v.RoomCode != "hunter2" {
		t.Fatalf("a correctly typed setting must still apply; room_code = %q", v.RoomCode)
	}
	var ok bool
	out := captureLog(t, func() { ok = ApplyDespiteBadValue(err, "config.json", "meshghost") })
	if !ok {
		t.Fatal("a type error must be survivable")
	}
	if strings.Contains(out, "everything else in the file still applies") {
		t.Fatalf("send_hz was dropped unnamed, so the message must not promise it applied: %q", out)
	}
	if !strings.Contains(out, "OTHER value in the file also has the wrong type") {
		t.Fatalf("message does not warn that a second mistyped value is gone too: %q", out)
	}
}

// TestAMistypedGroupDoesNotPrintAGoTypeName covers both non-scalar shapes: a group in braces and a list in brackets.
func TestAMistypedGroupDoesNotPrintAGoTypeName(t *testing.T) {
	type replaySection struct {
		Gzip bool `json:"gzip"`
	}
	cases := []struct {
		name, doc, key, wantShape string
	}{
		{"a group given a string", `{"replay": "yes"}`, "replay", `"replay": { ... }`},
		{"a list given a string", `{"features": "world"}`, "features", `"features": [ ... ]`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var v struct {
				Replay   *replaySection `json:"replay"`
				Features *[]string      `json:"features"`
			}
			err := json.Unmarshal([]byte(tc.doc), &v)
			if err == nil {
				t.Fatal("expected a type error")
			}
			var ok bool
			out := captureLog(t, func() { ok = ApplyDespiteBadValue(err, "config.json", "meshghost") })
			if !ok {
				t.Fatal("a type error must be survivable")
			}
			if !strings.Contains(out, tc.key) {
				t.Fatalf("warning does not name the offending key: %q", out)
			}
			if !strings.Contains(out, tc.wantShape) {
				t.Errorf("message does not show the shape the key needs.\n got: %q\nwant it to contain: %q", out, tc.wantShape)
			}
			// Spelled the way reflect spells them, so a regression fails rather than a paraphrase.
			for _, goName := range []string{"cfg.replaySection", "[]string", "struct {"} {
				if strings.Contains(out, goName) {
					t.Errorf("message prints a Go type name (%q) to a player: %q", goName, out)
				}
			}
		})
	}
}
