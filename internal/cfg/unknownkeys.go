package cfg

// A config key that is not a setting is warned about, since a typo'd key otherwise does nothing, silently. Not
// json.DisallowUnknownFields: the file is shared, so only the sections this binary owns are checked, and a warning
// never refuses the file. The known keys come from the struct's json tags by reflection, so they cannot drift.

import (
	"encoding/json"
	"log"
	"reflect"
	"sort"
	"strings"
)

// WarnUnknownKeys logs one line listing the keys in raw with no field in v's struct type, recursing into the nested
// sections it owns; only v's type is read. where names the section ("client", "client.replay").
//
// notSettings names keys another reader of the shared file owns, qualified like where ("client.autostart"):
// reflection cannot tell them from a typo, so the caller says so, and they are neither reported nor recursed into.
// Anything it cannot check (raw not an object, a non-struct type, a map field whose keys are the player's) is silent.
func WarnUnknownKeys(raw []byte, v any, path, prog, where string, notSettings map[string]bool) {
	t := structType(reflect.TypeOf(v))
	if t == nil {
		return
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		// Not an object: ApplyDespiteBadValue's business.
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
		// Lower-cased on both sides: encoding/json matches a key case-insensitively, so this check must too.
		known[strings.ToLower(name)] = f.Type
	}

	var unknown []string
	for key, val := range obj {
		if notSettings[where+"."+key] {
			continue
		}
		ft, ok := known[strings.ToLower(key)]
		if !ok {
			unknown = append(unknown, key)
			continue
		}
		if nested := structType(ft); nested != nil {
			WarnUnknownKeys(val, reflect.New(nested).Elem().Interface(), path, prog, where+"."+key, notSettings)
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

func structType(t reflect.Type) reflect.Type {
	for t != nil && t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == nil || t.Kind() != reflect.Struct {
		return nil
	}
	return t
}

func jsonName(f reflect.StructField) (string, bool) {
	tag, ok := f.Tag.Lookup("json")
	if !ok {
		// No tag: encoding/json uses the Go field name verbatim.
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
