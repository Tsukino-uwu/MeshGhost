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
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
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
	size := int64(0)
	if fi, err := f.Stat(); err == nil {
		size = fi.Size()
	}
	return &rotatingLog{name: name, prog: prog, f: f, size: size, rotateAt: MaxLogBytes}
}

// rotatingLog is the writer OpenLogFile hands back: the file, plus the same
// rotation the opener performs, applied WHILE RUNNING. Until 2026-09-02 the cap
// was checked only at open, so a long-running relay -- the normal life of a
// relay -- grew its log without bound, and under a connection flood that is a
// disk filled from outside (the 2026-09-02 adversarial review, ADR 0044). A
// write that would carry the file past MaxLogBytes first closes it, renames it
// to .1 and reopens, so the bound holds for the life of the process rather than
// for its first second. Best-effort like the opener: if the rename fails (a
// locked file, a locked .1, an odd filesystem) the log keeps appending to the
// same file and backs the next attempt off by a further MaxLogBytes rather
// than re-trying on every line -- see rotateLocked -- and if the reopen fails
// the writer says so once and drops output rather than crashing the program
// for its log. The mutex is defence in depth -- the log
// package already serialises its writes -- so a second writer added later is
// not a silent race.
type rotatingLog struct {
	mu   sync.Mutex
	name string
	prog string
	f    *os.File
	size int64
	// rotateAt is the size a write may not carry the file past. Normally
	// MaxLogBytes; raised by another MaxLogBytes each time a rotation runs and
	// the file is still over the cap afterwards, which is the only way to tell
	// that the rename did not happen. See rotateLocked for what that buys.
	rotateAt int64
	// rotations counts rotateLocked calls. It exists for
	// TestARotationThatCannotRenameStopsRetrying, which asserts the backoff by
	// counting attempts rather than by reading a log line -- the retry storm
	// this bounds is invisible in the log's contents, since every line it
	// costs still gets written.
	rotations int
	dead      bool
}

func (r *rotatingLog) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.dead {
		return len(p), nil
	}
	if r.size > 0 && r.size+int64(len(p)) > r.rotateAt {
		r.rotateLocked()
		if r.dead {
			return len(p), nil
		}
	}
	n, err := r.f.Write(p)
	r.size += int64(n)
	return n, err
}

// Close releases the file. Neither binary calls it (the log lives as long as the
// process), but a test that opens one in a temp directory must, or Windows
// refuses to delete the directory.
func (r *rotatingLog) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.dead || r.f == nil {
		return nil
	}
	r.dead = true
	return r.f.Close()
}

// rotateLocked closes the file, renames it to .1, and reopens -- and then
// decides what to do when that did not actually shrink anything.
//
// A failed rename is ORDINARY, not exotic (2026-09-08 review, G1). Two copies
// of one game run from the same folder share a meshghost.log, because the
// adapter sets the child core's working directory to the game folder, and that
// two-client setup is the standard way this repo is tested. Go opens without
// FILE_SHARE_DELETE, so while one process holds the file the other's rename
// fails. Until 2026-09-08 the reopen simply re-Stat'ed and restored size from
// the file that was still there, which left size over MaxLogBytes -- so the cap
// test in Write was true again on the NEXT line, and every line after that, for
// the life of the process: a Close+Rename+OpenFile+Stat per log line, forever,
// with no backoff and nothing said. The same code is the relay's disk bound
// (ADR 0044), where the log rate is a connection flood's to set.
//
// What it does instead: keep appending (a log line is never dropped -- the
// evidence of why a client died is the whole reason this file appends at all)
// and push the next attempt out by another MaxLogBytes. So a log that cannot be
// rotated grows, but it retries at most once per MiB written rather than once
// per line, and a lock that goes away -- the other game closing -- is picked up
// at the next attempt without anyone restarting anything. Refusing to rotate
// ever again would be simpler and would make that unrecoverable.
//
// The notice goes into the file directly rather than through log.Printf,
// which would DEADLOCK: this runs inside the writer log itself calls, and
// log.Logger.output holds outMu across that Write (go1.26.5 log/log.go:242),
// a plain sync.Mutex. The reopen-failure line below had the same latent
// problem and is written the same way.
func (r *rotatingLog) rotateLocked() {
	r.rotations++
	// Windows refuses to rename an open file, so close first.
	_ = r.f.Close()
	_ = os.Rename(r.name, r.name+".1")
	f, err := os.OpenFile(r.name, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: warning: could not reopen log file %s after rotating it: %v (log output will only appear in this window from now on)\n", r.prog, r.name, err)
		r.dead = true
		return
	}
	r.f = f
	r.size = 0
	if fi, err := f.Stat(); err == nil {
		// A failed rename leaves the old contents in place; count them.
		r.size = fi.Size()
	}
	if r.size < MaxLogBytes {
		r.rotateAt = MaxLogBytes
		return
	}
	r.rotateAt = r.size + MaxLogBytes
	notice := fmt.Sprintf("%s: warning: could not rotate %s to %s.1 -- another process is probably "+
		"holding one of them (two copies of a game run from the same folder share this file). It "+
		"keeps appending, and rotating is re-tried once every %d bytes rather than on every line.\n",
		r.prog, r.name, r.name, MaxLogBytes)
	n, _ := r.f.Write([]byte(notice))
	r.size += int64(n)
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
//
// What it must NOT say is "that ONE setting is being ignored -- everything else
// in the file still applies", which is what it said until 2026-09-08 (review
// G10). encoding/json keeps only the FIRST UnmarshalTypeError while skipping
// EVERY mistyped value, so a file with two wrong types loses both and hears
// about one: the second is dropped silently, with the message actively telling
// its author it still applied. Named settings are still the far more useful
// half, so the message names the one it has and says plainly that another
// wrong-typed value would be gone too and unnamed -- fix this one, re-run, see
// the next.
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
	//
	// Switched on the KIND, not on Type.String(), since 2026-09-08. The old
	// switch listed "bool", "int" and "string" and fell through to printing
	// Type.String() itself -- so a mistyped group or list told a player their
	// config needed "a main.replayFileConfig" or "a []string", which names a Go
	// declaration they cannot see and gives them nothing to type. A pointer is
	// unwrapped first because every fileConfig field is one (that is what makes
	// an absent key distinguishable from an empty one, see Override).
	badType := typeErr.Type
	for badType.Kind() == reflect.Pointer {
		badType = badType.Elem()
	}
	var wanted, example string
	switch badType.Kind() {
	case reflect.Bool:
		wanted, example = "true or false, without quotes", "true"
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64,
		reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64,
		reflect.Float32, reflect.Float64:
		wanted, example = "a plain number, without quotes", "8"
	case reflect.String:
		// A string field given a non-string: quotes are the fix, not the problem,
		// so the parenthetical below would be actively misleading. Say less.
		log.Printf("%s: warning: config file %s: \"%s\" was given a %s, but it needs text in "+
			"quotes. %s", prog, path, key, typeErr.Value, alsoIgnored)
		return true
	default:
		// A group of settings or a list: there is no one-line example worth
		// printing (the contents are what went wrong, and they differ per key),
		// and the quotes parenthetical below is about scalars. Describe the
		// SHAPE in the punctuation the player can see in their own file.
		shape := "a group of settings in braces, like \"%s\": { ... }"
		if k := badType.Kind(); k == reflect.Slice || k == reflect.Array {
			shape = "a list in square brackets, like \"%s\": [ ... ]"
		}
		log.Printf("%s: warning: config file %s: \"%s\" was given a %s, but it needs "+shape+
			". %s", prog, path, key, typeErr.Value, key, alsoIgnored)
		return true
	}

	log.Printf("%s: warning: config file %s: \"%s\" was given a %s, but it needs %s. %s "+
		"(Quotes make a value text: \"%s\": %s, not \"%s\": \"%s\".)",
		prog, path, key, typeErr.Value, wanted, alsoIgnored, key, example, key, example)
	return true
}

// alsoIgnored is the tail every bad-value message above shares. It replaced
// "That ONE setting is being ignored -- everything else in the file still
// applies" on 2026-09-08: that sentence was a promise the decoder does not
// keep, since a second mistyped value is skipped too and never named (review
// G10). The reassurance the 2026-08-16 message was written for -- your room
// code did not just evaporate -- is the first half and stays.
const alsoIgnored = "That setting is being ignored and everything correctly typed still applies, " +
	"but if any OTHER value in the file also has the wrong type it is being ignored too and only " +
	"the first one can be named here -- fix this one and run again to see whether there is another."

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
