package goals

import (
	"path/filepath"
	"testing"
)

// TestTrackedGoalsFilesLoad loads every game's goals file in the knowledge store: a typo in one fails here, not in a
// session that reads it.
func TestTrackedGoalsFilesLoad(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("..", "games", "*", "goals.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatal("no games/*/goals.json found: the glob or the working folder is wrong")
	}
	for _, f := range files {
		g, err := Load(f)
		if err != nil {
			t.Errorf("%v", err)
			continue
		}
		if game := filepath.Base(filepath.Dir(f)); g.Game != game {
			t.Errorf("%s names game %q, in the folder %q", f, g.Game, game)
		}
		if note := SizeNote(f); note != "" {
			t.Errorf("%s", note)
		}
	}
}
