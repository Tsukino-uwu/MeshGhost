package cfg

// A RENAMED CONFIG KEY KEEPS WORKING, AND SAYS SO ONCE.
//
// Renaming a key in a shipped config.json is not free: the player's existing
// file still spells it the old way. Without help, that file's "room" becomes an
// unknown key -- warned about by WarnUnknownKeys and then IGNORED -- and the
// setting silently reverts to its built-in default. For most keys that is an
// annoyance; for the room it is the worst kind of failure this project has,
// because the player lands in a REAL room that simply is not the one their
// friends are in, with nothing on screen saying why nobody showed up.
//
// So a rename ships with its old spelling aliased here. RenameOldKeys rewrites
// the RAW BYTES before anything decodes them: by the time the decoder,
// ApplyDespiteBadValue and WarnUnknownKeys see the file, only the current names
// exist. That is deliberate and it is what keeps the rest of the package honest
// -- the alternative, a second json tag or a second accepted-key list, would
// make the old spelling a permanently documented setting and would have to be
// kept in sync with the warner by hand, which is the drift WarnUnknownKeys'
// reflection was written to avoid.
//
// ONLY THE TOP LEVEL OF THE NAMED SECTION IS TOUCHED. "client.name" is the
// player's nametag; "client.replay.name" and "client.chaser.name" are different
// settings that happen to share a word, and renaming one must never reach the
// others. Nothing here recurses, and a test pins that.

import (
	"encoding/json"
	"log"
	"sort"
)

// RenameOldKeys moves each renames[old] -> new key found at the top level of
// the named section, logging one line per key it moved so the player knows to
// update the file. The returned bytes are byte-identical to data when there is
// nothing to do -- an unparseable file, a missing section, or no old key
// present -- so a malformed config still reaches ApplyDespiteBadValue exactly
// as it did before.
//
// path names the file and prog the binary, matching every other message in this
// package. When BOTH spellings are present the current one wins, because that is
// the one the player edited most recently in every plausible order of events:
// they copied a new shipped config and pasted their old value in beside it.
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

	// Sorted, so two runs of one file log the same lines in the same order.
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
