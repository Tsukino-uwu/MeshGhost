// Package cfg holds the config-file plumbing shared by cmd/meshghost and cmd/meshghost-relay: how both binaries treat
// a hand-edited config file. It is internal because these are our binaries' decisions, not a contract to import, and
// it knows nothing about any game.
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

// MaxLogBytes is the size at which a binary's own .log is rotated to .log.1, keeping one generation. The logs append,
// so without a cap an autostarted client's log would grow forever.
const MaxLogBytes = 1 << 20

// OpenLogFile opens name for appending, creating it: an autostarted client has no console, so this file is the only
// thing a remote tester can send back, and a respawned process must not truncate away why the last one died. It
// returns nil, with a warning, if the file cannot be opened, and leaves composing the writer to the caller, since the
// client and the relay combine it differently.
func OpenLogFile(name, prog string) io.Writer {
	if fi, err := os.Stat(name); err == nil && fi.Size() >= MaxLogBytes {
		// Best-effort: a failed rotate still leaves the append below.
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

// rotatingLog applies OpenLogFile's rotation while running, so the bound holds for the life of a relay under a
// connection flood, not just at open. A failed reopen drops output rather than crash the program for its log.
type rotatingLog struct {
	mu   sync.Mutex
	name string
	prog string
	f    *os.File
	size int64
	// rotateAt is the size a write may not carry the file past: MaxLogBytes, raised by another MaxLogBytes when a
	// rotation leaves the file still over the cap, the only sign the rename did not happen.
	rotateAt int64
	// rotations counts rotateLocked calls, so a test can assert the backoff: the retry storm is invisible in the log's
	// contents.
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

// Close releases the file. Neither binary calls it, but a test in a temp directory must, or Windows refuses to delete
// the directory.
func (r *rotatingLog) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.dead || r.f == nil {
		return nil
	}
	r.dead = true
	return r.f.Close()
}

// rotateLocked closes the file, renames it to .1 and reopens. The rename fails whenever another process holds either
// file (Go opens without FILE_SHARE_DELETE, and two copies of a game run from one folder share a log), so then it keeps
// appending and pushes the next attempt out by another MaxLogBytes rather than retrying on every line. Its notices
// bypass log.Printf, which would deadlock: log.Logger holds its mutex across this Write.
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

// ExplicitFlags reports which flags were typed on the command line rather than left at their default, which is what
// lets a flag beat the config file (see Override). flag.Visit walks only the flags that were set.
func ExplicitFlags() map[string]bool {
	explicit := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
	return explicit
}

// Override applies one config-file value to one flag target unless that flag was given explicitly: explicit flag beats
// config file beats built-in default. A nil value means the key was absent from the file, which is why every
// fileConfig field is a pointer.
func Override[T any](explicit map[string]bool, flagName string, target, value *T) {
	if value == nil || explicit[flagName] {
		return
	}
	*target = *value
}

// OverrideDuration is Override for a duration string ("250ms") held as a time.Duration. A value that does not parse is
// warned about under its config key and skipped, so one unreadable duration does not cost the settings around it.
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

// StripBOM removes a leading UTF-8 byte-order mark, which some Windows editors write and encoding/json refuses, so a
// file that looks correct is not discarded whole. A UTF-16 file cannot be salvaged this cheaply: it returns nil with a
// warning naming the fix.
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

// ApplyDespiteBadValue reports whether the caller should keep the config it just decoded despite err, and logs the
// right thing either way. On a type mismatch encoding/json skips that value and still fills every other field, so one
// mistyped value must not cost the whole file; a syntax error still does. Only the first type error is kept while
// every mistyped value is skipped, so the message names one and says another may be gone too.
func ApplyDespiteBadValue(err error, path, prog string) bool {
	var typeErr *json.UnmarshalTypeError
	if !errors.As(err, &typeErr) {
		log.Printf("%s: warning: could not parse config file %s: %v -- every setting in it "+
			"is being IGNORED and built-in defaults used instead", prog, path, err)
		return false
	}

	// Field arrives as "client.show_console"; name the key the player typed.
	key := typeErr.Field
	if i := strings.LastIndex(key, "."); i >= 0 {
		key = key[i+1:]
	}

	// Switched on the kind, never Type.String(), so the message never names a Go type the player cannot see; the
	// pointer every fileConfig field is gets unwrapped first.
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
		// Quotes are the fix here, not the problem, so the parenthetical below would mislead.
		log.Printf("%s: warning: config file %s: \"%s\" was given a %s, but it needs text in "+
			"quotes. %s", prog, path, key, typeErr.Value, alsoIgnored)
		return true
	default:
		// A group or a list has no one-line example: describe its shape in the punctuation the player sees.
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

// alsoIgnored is the tail every bad-value message shares: a second mistyped value is skipped too and never named.
const alsoIgnored = "That setting is being ignored and everything correctly typed still applies, " +
	"but if any OTHER value in the file also has the wrong type it is being ignored too and only " +
	"the first one can be named here -- fix this one and run again to see whether there is another."

// ReloadRefusal says why a saved config file must not be applied mid-session, or "" when it may. A re-read lays the
// file over the flag defaults, so a file that cannot be read, is empty, does not parse or has lost this binary's
// section would apply the defaults live; what is live stays until a save that parses. A wrong-typed value is not a
// refusal: ApplyDespiteBadValue keeps every other setting.
func ReloadRefusal(path, prog, section string) string {
	data, _, err := ReadConfigFile(path, prog)
	switch {
	case err != nil:
		return fmt.Sprintf("could not be read (%v)", err)
	case data == nil:
		return "is empty"
	}
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return fmt.Sprintf("does not parse (%v)", err)
	}
	if raw, ok := root[section]; !ok || string(bytes.TrimSpace(raw)) == "null" {
		return fmt.Sprintf("has no %q section", section)
	}
	return ""
}

// ReadConfigFile resolves path for display, reads it, strips a BOM, and says whether there is any JSON worth
// unmarshaling: data is nil for an empty or BOM-only file. shown is the absolute path for messages, since "nothing
// changed" is nearly always a different config.json. err is os.ReadFile's, returned because the two binaries treat a
// missing file differently.
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
	// An empty file is nothing configured, not a broken one; on Windows `-config nul` reads as zero bytes.
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, shown, nil
	}
	return data, shown, nil
}
