// Package cfg holds the config-file plumbing shared by cmd/meshghost and
// cmd/meshghost-relay.
//
// It exists because both mains had their own copy and said so in a comment --
// "mirrored in cmd/meshghost-relay/main.go, the same way applyFileConfig is" --
// which is a duplication that announces itself and then drifts anyway. StripBOM
// was still byte-identical between the two when this package was written
// (2026-08-25); ApplyDespiteBadValue had already diverged.
//
// Deliberately internal/. These are decisions about how OUR two binaries treat a
// hand-edited config file, not a contract anyone should import -- unlike the six
// library packages at the repo root, which are public on purpose.
//
// Nothing here knows anything about a game, and nothing here may learn: this is
// below the level the game-blindness rules police (internal/gameblind), and it
// is shared by the client and the server, which is exactly the boundary
// CLAUDE.md keeps them on opposite sides of.
package cfg

import (
	"bytes"
	"encoding/json"
	"errors"
	"log"
	"strings"
)

// StripBOM removes a leading UTF-8 byte-order mark from a config file's
// contents, and refuses a UTF-16 one outright (returning nil) with a message
// naming the actual fix.
//
// Both cases exist because config.json is a file a non-developer edits by hand on
// Windows: a BOM is three bytes some editors (Notepad's "UTF-8 with BOM" save
// option, PowerShell 5.1's `Out-File -Encoding utf8`) put before the opening
// brace, and encoding/json refuses them -- so a file that looks completely
// correct to whoever edited it gets discarded whole, silently taking every
// setting in it along with it, room_code included. Found while testing the
// only_game setting.
//
// The BOM is stripped rather than warned about (the file is valid UTF-8 either
// way, and the offending bytes are invisible in an editor); UTF-16 cannot be
// salvaged this cheaply, so it gets an actionable warning instead of the cryptic
// JSON error it would otherwise produce.
//
// prog is the binary's own name, so the warning says which program is talking.
func StripBOM(data []byte, path, prog string) []byte {
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
	if bytes.HasPrefix(data, []byte{0xFF, 0xFE}) || bytes.HasPrefix(data, []byte{0xFE, 0xFF}) {
		log.Printf("%s: warning: config file %s looks like it was saved as UTF-16 (\"Unicode\" in "+
			"Notepad's save-as list) -- re-save it as UTF-8. Every setting in it is being IGNORED "+
			"and built-in defaults used instead.", prog, path)
		return nil
	}
	return data
}

// ApplyDespiteBadValue decides whether a json.Unmarshal error is survivable, and
// logs the right thing either way. It returns true when the caller should carry
// on applying the config it just decoded.
//
// This exists because a single mistyped value used to cost a user their ENTIRE
// config. Found live 2026-08-16: a Proton tester wrote `"show_console": "true"`
// -- quoted, so a JSON string where a bool belongs -- and got every other setting
// silently reverted to defaults, including their name (they joined as "player")
// and, worse for a host, room_code.
//
// The cruel part is that Go had already done the right thing. encoding/json does
// not abort on a type mismatch: it records the first UnmarshalTypeError, skips
// that one value, and keeps decoding every other field. So the struct handed back
// is fully populated apart from the offending key -- and the old code threw it
// away on `err != nil`.
//
// A SyntaxError is different and still fatal to the file: a missing comma or
// stray brace means the rest genuinely cannot be trusted to be what the user
// meant. That is the case the whole-file warning was written for, and it keeps
// it.
func ApplyDespiteBadValue(err error, path, prog string) bool {
	var typeErr *json.UnmarshalTypeError
	if !errors.As(err, &typeErr) {
		log.Printf("%s: warning: could not parse config file %s: %v -- every setting in it "+
			"is being IGNORED and built-in defaults used instead", prog, path, err)
		return false
	}

	// Field arrives as "client.show_console"; a player knows it as the key they
	// typed. The Go type name would mean nothing to them either, so say what a
	// value of the right type actually looks like in the file.
	key := typeErr.Field
	if i := strings.LastIndex(key, "."); i >= 0 {
		key = key[i+1:]
	}

	// The example is derived from the type rather than hardcoded per binary. Both
	// copies used to hardcode one -- the client always said `true`, the relay
	// always said `8` -- so each was wrong whenever the mistyped key happened to
	// be of the other kind, which is precisely when a confused user is reading it.
	wanted, example := typeErr.Type.String(), "1"
	switch typeErr.Type.String() {
	case "bool":
		wanted, example = "true or false, without quotes", "true"
	case "int":
		wanted, example = "a plain number, without quotes", "8"
	case "string":
		// A string field given a non-string: quotes are the fix, not the problem,
		// so the parenthetical below would be actively misleading. Say less.
		log.Printf("%s: warning: config file %s: \"%s\" was given a %s, but it needs text in "+
			"quotes. That ONE setting is being ignored -- everything else in the file still "+
			"applies.", prog, path, key, typeErr.Value)
		return true
	}

	log.Printf("%s: warning: config file %s: \"%s\" was given a %s, but it needs %s. That ONE "+
		"setting is being ignored -- everything else in the file still applies. (Quotes make a "+
		"value text: \"%s\": %s, not \"%s\": \"%s\".)",
		prog, path, key, typeErr.Value, wanted, key, example, key, example)
	return true
}
