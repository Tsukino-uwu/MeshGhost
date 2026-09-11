package cfg

// A KEY THAT IS NOT A SETTING SAYS SO NOW.
//
// A typo'd config key did nothing, silently: the JSON parsed, the value was
// ignored, and the setting the player thought they had changed kept its default.
// ApplyDespiteBadValue already covers a key with the WRONG TYPE, which is the
// same class of mistake with the same cost -- and that one is on record as
// having cost a tester their room code -- but a key with the wrong NAME went
// unremarked, which is the more likely typo of the two (`roomcode`, `min-send`,
// `connectto`).
//
// WHY NOT json.DisallowUnknownFields, which is the obvious tool: the file is
// shared. The ROOT object legitimately carries sections this binary knows
// nothing about -- an adapter's own, a future one's -- so refusing an unknown
// key there would be refusing someone else's setting. This walks the sections
// this binary DOES own and warns inside them, which is where a typo actually
// lands, and it warns rather than refuses: one misspelled key must not cost the
// twenty that were spelled right, the same rule ApplyDespiteBadValue follows.
//
// The known-key set comes from the struct's own json tags by reflection, so it
// cannot drift from the settings that exist -- a curated list would go stale the
// first time a setting was added, which is the failure mode this file is
// supposed to prevent rather than reproduce.

import (
	"encoding/json"
	"log"
	"reflect"
	"sort"
	"strings"
)

// WarnUnknownKeys logs one line per key in raw that has no counterpart in the
// struct type of v, recursing into nested objects it also owns.
//
// raw is the JSON object this section was decoded from, v a value of the type it
// was decoded INTO (the zero value is enough -- only its type is read). where
// names the section for the message ("client", "client.replay"), path the file
// and prog the binary, matching every other warning in this package.
//
// Silent on anything it cannot check: raw that is not an object, a type that is
// not a struct, a map-typed field (whose keys are the user's to choose). Being
// unable to check is not evidence of a mistake.
func WarnUnknownKeys(raw []byte, v any, path, prog, where string) {
	t := structType(reflect.TypeOf(v))
	if t == nil {
		return
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		// Not an object, or not parseable -- ApplyDespiteBadValue's business,
		// not this function's.
		return
	}
	known := map[string]reflect.Type{}
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		if f.PkgPath != "" { // unexported
			continue
		}
		name, ok := jsonName(f)
		if !ok {
			continue
		}
		known[name] = f.Type
	}

	var unknown []string
	for key, val := range obj {
		ft, ok := known[key]
		if !ok {
			unknown = append(unknown, key)
			continue
		}
		// A nested section this binary owns gets the same treatment: a typo
		// inside "replay" or "hotkeys" is exactly as silent as one beside them.
		if nested := structType(ft); nested != nil {
			WarnUnknownKeys(val, reflect.New(nested).Elem().Interface(), path, prog, where+"."+key)
		}
	}
	if len(unknown) == 0 {
		return
	}
	sort.Strings(unknown) // map order would make two runs of one file disagree
	names := make([]string, 0, len(known))
	for k := range known {
		names = append(names, k)
	}
	sort.Strings(names)
	log.Printf("%s: warning: config file %s has %d key(s) in %q that are not settings: %s -- "+
		"they are being IGNORED, so whatever they were meant to change is still at its default. "+
		"The settings this section accepts are: %s",
		prog, path, len(unknown), where, strings.Join(unknown, ", "), strings.Join(names, ", "))
}

// structType unwraps pointers and reports the struct type, or nil for anything
// else (a map, a slice, a scalar).
func structType(t reflect.Type) reflect.Type {
	for t != nil && t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == nil || t.Kind() != reflect.Struct {
		return nil
	}
	return t
}

// jsonName is the key this field is spelled as in the file, and false for a
// field the encoder skips.
func jsonName(f reflect.StructField) (string, bool) {
	tag, ok := f.Tag.Lookup("json")
	if !ok {
		// No tag: encoding/json uses the Go field name verbatim. Reported as
		// such rather than guessed at.
		return f.Name, true
	}
	name, _, _ := strings.Cut(tag, ",")
	if name == "-" {
		return "", false
	}
	if name == "" {
		return f.Name, true
	}
	return name, true
}
