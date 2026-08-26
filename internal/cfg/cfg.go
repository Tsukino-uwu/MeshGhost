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
	"flag"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// MaxLogBytes is the size at which a binary's own .log is rotated to .log.1 (one
// generation, then the older one is discarded). A cap is needed because the logs
// APPEND rather than truncating -- see OpenLogFile -- so without one a machine
// that autostarts a client with every game session would grow it forever.
//
// Both mains declared this constant separately, and the relay's comment said so:
// "Mirrors cmd/meshghost's own cap, for the same reason".
const MaxLogBytes = 1 << 20 // 1 MiB

// OpenLogFile opens (creating, and APPENDING to) a log file next to the process's
// working directory -- the same cwd config.json is read from, so it lands beside
// the exe in the normal double-click-from-the-package-folder case, and beside the
// mod in the autostarted case (the adapter sets the child's working directory; see
// the autostart ADR). This exists so a crash is still readable after the console
// window itself is gone: double-clicking an .exe opens a console that closes the
// instant the process exits, taking any error message with it -- see
// packaging/README.md's "No launcher .bat files" section.
//
// It appends rather than truncating. Once an adapter starts the client for you
// there is usually no console at all, so this file is the ONLY thing a remote
// tester can send back -- and a process that dies and gets respawned would
// truncate away the evidence of why it died, which is exactly the report worth
// having. The relay's copy used to truncate (os.Create) and was brought in line
// 2026-08-16, after the client's appending log was the only reason a Proton bug
// report could be diagnosed remotely: six runs in one file, each with its own
// banner. One rotation at MaxLogBytes bounds the growth that buys.
//
// Returns nil, with a warning, if the file cannot be opened (e.g. a read-only
// folder). The CALLER decides what that means -- the two binaries genuinely
// differ, and that difference is the whole reason this returns a plain writer
// rather than a composed one: the client appends it to a list of writers it may
// also add a console to, while the relay tees it with os.Stderr. Expressing that
// as a bool parameter here would put a caller's composition inside the opener.
//
// prog is the binary's own name, so the warning says which program is talking.
func OpenLogFile(name, prog string) io.Writer {
	if fi, err := os.Stat(name); err == nil && fi.Size() >= MaxLogBytes {
		// Best-effort: a failed rotate must not cost us the log entirely, so
		// the error is deliberately ignored and the append below still runs.
		_ = os.Rename(name, name+".1")
	}
	f, err := os.OpenFile(name, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("%s: warning: could not open log file %s: %v (log output will only appear in this window)", prog, name, err)
		return nil
	}
	return f
}

// ExplicitFlags reports which flags were actually typed on the command line, as
// opposed to sitting at their default. It is what makes a flag beat the config
// file: Override below applies a file value only to a setting the caller did not
// pass explicitly.
//
// flag.Visit (not VisitAll) is the whole trick -- it walks only the flags that
// were Set. Both mains open-coded this identical two-liner.
func ExplicitFlags() map[string]bool {
	explicit := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
	return explicit
}

// Override applies one config-file value to one flag target, unless that flag was
// given explicitly on the command line. A nil value means the key was absent from
// the file, which is different from being present and empty -- that is why every
// field in both mains' fileConfig structs is a POINTER.
//
// This is the precedence rule the whole config system rests on -- explicit flag
// beats config file beats built-in default -- and it was written out by hand
// twenty-five times across the two mains as:
//
//	if fc.X != nil && !explicit["x"] {
//		*t.x = *fc.X
//	}
//
// Twenty-five chances to typo a flag name into a key that is never set, in a
// pattern too regular to reread carefully. TestOverride pins the precedence.
func Override[T any](explicit map[string]bool, flagName string, target, value *T) {
	if value == nil || explicit[flagName] {
		return
	}
	*target = *value
}

// OverrideDuration is Override for a setting the config file expresses as a
// duration string ("250ms") and the flag holds as a time.Duration. A value that
// does not parse is warned about and skipped, leaving the target alone -- one
// unreadable duration must not cost the settings around it, the same principle
// ApplyDespiteBadValue applies to one mistyped JSON value.
//
// key is the config-file key name (e.g. "interp"), so the warning names what the
// user typed rather than a Go field.
func OverrideDuration(explicit map[string]bool, flagName string, target *time.Duration, value *string, path, prog, key string) {
	if value == nil || explicit[flagName] {
		return
	}
	d, err := time.ParseDuration(*value)
	if err != nil {
		log.Printf("%s: warning: config file %s has an invalid %s value %q: %v", prog, path, key, *value, err)
		return
	}
	*target = d
}

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

// ReadConfigFile resolves path for display, reads it, strips a BOM, and says
// whether there is any JSON worth unmarshaling.
//
// One home since 2026-08-27, for the sequence both mains were carrying
// independently: filepath.Abs for the message, os.ReadFile, StripBOM, and the
// empty-file check -- including a byte-identical eight-line comment explaining
// why an empty file is not a broken one. That comment now lives here.
//
// data is nil when there is nothing to apply, which covers both a BOM-only
// file and an empty one. shown is the absolute path to name in any message,
// because "I edited config.json and nothing changed" is nearly always a
// different config.json than the one being read, and a relative path in the log
// answers that question with another question. err is os.ReadFile's, returned
// rather than handled: the two callers differ on a MISSING file (the client
// tells a player their settings are being ignored, the relay stays silent) and
// that difference is deliberate.
func ReadConfigFile(path, prog string) (data []byte, shown string, err error) {
	shown = path
	if abs, absErr := filepath.Abs(path); absErr == nil {
		shown = abs
	}
	data, err = os.ReadFile(path)
	if err != nil {
		return nil, shown, err
	}
	data = StripBOM(data, shown, prog)
	if data == nil {
		return nil, shown, nil
	}
	// An empty file is "nothing configured", not a broken config. Without this,
	// json.Unmarshal returns "unexpected end of JSON input" and the caller warns
	// that every setting is being IGNORED -- which reads like a broken install
	// and is not true, since there was nothing in it to ignore. Reachable in the
	// ordinary way on Windows: `-config nul` is how a dev script says "no
	// config", and os.ReadFile("nul") succeeds with zero bytes rather than
	// failing os.IsNotExist.
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, shown, nil
	}
	return data, shown, nil
}
