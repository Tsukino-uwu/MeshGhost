package cfg

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

var clientRenames = map[string]string{
	"room":       "room_name",
	"name":       "player_name",
	"name_color": "player_name_color",
}

// value reads one top-level key out of the named section, so a test asserts on
// what a decoder would see rather than on the exact bytes of a re-marshal.
func value(t *testing.T, data []byte, section, key string) (string, bool) {
	t.Helper()
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		t.Fatalf("output is not JSON: %v\n%s", err, data)
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(root[section], &obj); err != nil {
		t.Fatalf("section %q is not an object: %v", section, err)
	}
	raw, ok := obj[key]
	if !ok {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		t.Fatalf("%s.%s is not a string: %v", section, key, err)
	}
	return s, true
}

// AN OLD SPELLING STILL WORKS, AND SAYS SO. The whole point of the alias: a
// player's existing file keeps the room they typed. Without this, "room" became
// an unknown key and they joined "default" -- a real room, just not their
// friends' one, with nothing on screen explaining it.
func TestAnOldKeyStillAppliesAndSaysSo(t *testing.T) {
	in := []byte(`{"client":{"room":"castle","name":"me","name_color":"#F00","interp":"450ms"}}`)
	var out []byte
	log := captureLog(t, func() {
		out = RenameOldKeys(in, "client", clientRenames, "C:\\x\\config.json", "meshghost")
	})
	for key, want := range map[string]string{"room_name": "castle", "player_name": "me", "player_name_color": "#F00"} {
		got, ok := value(t, out, "client", key)
		if !ok || got != want {
			t.Errorf("client.%s = %q (present=%v), want %q", key, got, ok, want)
		}
	}
	if _, ok := value(t, out, "client", "room"); ok {
		t.Error("the old key survived the rename, so the decoder would see both")
	}
	if got, _ := value(t, out, "client", "interp"); got != "450ms" {
		t.Errorf("an untouched key was lost in the rewrite: interp = %q", got)
	}
	for _, want := range []string{"room", "room_name", "name_color", "player_name_color"} {
		if !strings.Contains(log, want) {
			t.Errorf("the notice does not mention %q, so the player cannot fix the file:\n%s", want, log)
		}
	}
}

// BOTH SPELLINGS PRESENT: the current name wins. Someone who pastes an old
// value in beside a freshly-copied shipped config has a file carrying both, and
// the one they most recently edited is the current one.
func TestTheCurrentNameWinsOverTheOldOne(t *testing.T) {
	in := []byte(`{"client":{"room":"old","room_name":"new"}}`)
	var out []byte
	log := captureLog(t, func() {
		out = RenameOldKeys(in, "client", clientRenames, "cfg.json", "meshghost")
	})
	if got, _ := value(t, out, "client", "room_name"); got != "new" {
		t.Errorf("room_name = %q, want the current name's value %q", got, "new")
	}
	if _, ok := value(t, out, "client", "room"); ok {
		t.Error("the old key was left behind for the unknown-key warner to complain about")
	}
	if !strings.Contains(log, "both") {
		t.Errorf("the player is not told their file carries both spellings:\n%s", log)
	}
}

// THE RENAME MUST NOT REACH A NESTED SECTION. "client.name" is the player's own
// nametag; "client.replay.name" labels a recording and "client.chaser.name"
// labels a chaser. They share a word and mean different things, so a shim that
// recursed would quietly rename two settings nobody asked to rename.
func TestNestedSectionsKeepTheirOwnKeys(t *testing.T) {
	in := []byte(`{"client":{"replay":{"name":"pb","color":"#FFF"},"chaser":{"name":"Why?"}}}`)
	var out []byte
	log := captureLog(t, func() {
		out = RenameOldKeys(in, "client", clientRenames, "cfg.json", "meshghost")
	})
	if !bytes.Equal(in, out) {
		t.Fatalf("a file with nothing to rename was rewritten:\nin  %s\nout %s", in, out)
	}
	if log != "" {
		t.Fatalf("a file with nothing to rename logged something:\n%s", log)
	}
}

// WHAT IT CANNOT CHECK, IT LEAVES ALONE -- byte for byte, and silently. A
// malformed file is ApplyDespiteBadValue's business, and being unable to look is
// not evidence of a mistake.
func TestUncheckableInputIsReturnedUnchanged(t *testing.T) {
	cases := map[string]string{
		"not JSON at all":       `{"client":{"room":`,
		"section is not object": `{"client":"nope"}`,
		"section absent":        `{"server":{"room":"x"}}`,
		"no old key present":    `{"client":{"room_name":"castle","player_name":"me"}}`,
		"empty object":          `{}`,
	}
	for what, in := range cases {
		t.Run(what, func(t *testing.T) {
			var out []byte
			log := captureLog(t, func() {
				out = RenameOldKeys([]byte(in), "client", clientRenames, "cfg.json", "meshghost")
			})
			if !bytes.Equal([]byte(in), out) {
				t.Errorf("input was rewritten:\nin  %s\nout %s", in, out)
			}
			if log != "" {
				t.Errorf("logged on input it cannot act on:\n%s", log)
			}
		})
	}
}

// A SECTION THIS BINARY DOES NOT OWN IS UNTOUCHED. The root object carries
// sections belonging to other readers (the relay's "server", a mod's own), and
// a rename in one must never reach another.
func TestOtherSectionsAreUntouched(t *testing.T) {
	in := []byte(`{"client":{"room":"castle"},"server":{"room":"kept"}}`)
	var out []byte
	captureLog(t, func() {
		out = RenameOldKeys(in, "client", clientRenames, "cfg.json", "meshghost")
	})
	if got, ok := value(t, out, "server", "room"); !ok || got != "kept" {
		t.Errorf("server.room = %q (present=%v), want it left exactly as it was", got, ok)
	}
	if _, ok := value(t, out, "server", "room_name"); ok {
		t.Error("the rename reached a section this caller does not own")
	}
}
