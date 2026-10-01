package cfg

// A renamed config key keeps working: without an alias the player's old spelling becomes an unknown key and the
// setting silently reverts to its default. The raw bytes are rewritten before anything decodes them, so the decoder
// and WarnUnknownKeys only ever see current names. Only the top level of the named section is touched, since
// "client.replay.name" and "client.chaser.name" are not "client.name".

import (
	"encoding/json"
	"log"
	"sort"
)

// RenameOldKeys moves each renames[old] -> new key found at the top level of the named section, logging one line per
// key so the player knows to update the file. With nothing to do (an unparseable file, a missing section, no old key)
// it returns data unchanged, so a malformed config still reaches ApplyDespiteBadValue as it was. When both spellings
// are present the current one wins: it is the one the player most likely edited last.
func RenameOldKeys(data []byte, section string, renames map[string]string, path, prog string) []byte {
	if len(renames) == 0 {
		return data
	}
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return data
	}
	rawSection, ok := root[section]
	if !ok {
		return data
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(rawSection, &obj); err != nil {
		return data
	}

	// Sorted, so two runs log the same lines in the same order.
	olds := make([]string, 0, len(renames))
	for old := range renames {
		olds = append(olds, old)
	}
	sort.Strings(olds)

	moved := false
	for _, old := range olds {
		val, present := obj[old]
		if !present {
			continue
		}
		newName := renames[old]
		delete(obj, old)
		moved = true
		if _, dup := obj[newName]; dup {
			log.Printf("%s: config file %s has both %q and %q in %q -- %q is the current name and is the "+
				"one being used; the old %q is ignored and can be deleted.",
				prog, path, old, newName, section, newName, old)
			continue
		}
		obj[newName] = val
		log.Printf("%s: config file %s still calls %q by its old name %q (in %q) -- the old name keeps "+
			"working, and your value is being used, but please rename it to %q.",
			prog, path, newName, old, section, newName)
	}
	if !moved {
		return data
	}

	newSection, err := json.Marshal(obj)
	if err != nil {
		return data
	}
	root[section] = newSection
	out, err := json.Marshal(root)
	if err != nil {
		return data
	}
	return out
}
