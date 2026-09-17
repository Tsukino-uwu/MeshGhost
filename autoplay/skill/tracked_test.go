package skill

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestTrackedSkillsLoad loads every skill in the knowledge store, and every skill each one calls, the way run_skill
// does before its first call: a typo in one fails here, not in a session.
func TestTrackedSkillsLoad(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("..", "games", "*", "skills", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatal("no games/*/skills/*.json found: the glob or the working folder is wrong")
	}
	for _, f := range files {
		s, err := Load(f)
		if err != nil {
			t.Errorf("%v", err)
			continue
		}
		dir := Dir{Path: filepath.Dir(f), Game: filepath.Base(filepath.Dir(filepath.Dir(f))), Variant: s.Variant}
		name := strings.TrimSuffix(filepath.Base(f), ".json")
		// No caller and no tool list: resolve alone, which loads and checks the whole tree without a call.
		if err := (Runner{Skills: dir}).resolve(name, map[string]*Skill{}, 0); err != nil {
			t.Errorf("%s: %v", f, err)
		}
	}
}
