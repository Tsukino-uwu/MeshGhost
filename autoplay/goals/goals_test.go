package goals

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const storyGoals = `{
  "game": "emerald", "variant": "vanilla",
  "goals": [
    {"id": "stone_badge", "description": "ROXANNE's badge", "done_when": [{"path": "badges", "contains": 1}]},
    {"id": "in_dewford", "description": "standing in Dewford", "done_when": [{"path": "location.map", "equals": "0.11"}], "hints": "route.md#dewford"},
    {"id": "knuckle_badge", "description": "BRAWLY's badge", "done_when": [{"path": "badges", "contains": 2}]},
    {"id": "dynamo_badge", "description": "WATTSON's badge", "done_when": [{"path": "badges", "contains": 3}, {"path": "badge_count", "min": 3}]}
  ]
}`

func mustParse(t *testing.T, text string) *File {
	t.Helper()
	g, err := Parse(strings.NewReader(text))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return g
}

func state(t *testing.T, text string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(text), &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestParseRefuses(t *testing.T) {
	cases := map[string]struct{ text, want string }{
		"an unknown field":   {`{"game":"g","goals":[{"id":"a","description":"d","done_when":[{"path":"x","exists":true}],"hint":"typo"}]}`, "unknown field"},
		"no goals":           {`{"game":"g","goals":[]}`, "at least one goal"},
		"a bad game name":    {`{"game":"../g","goals":[{"id":"a","description":"d","done_when":[{"path":"x","exists":true}]}]}`, "game must name"},
		"a bad id":           {`{"game":"g","goals":[{"id":"a b","description":"d","done_when":[{"path":"x","exists":true}]}]}`, "id must be"},
		"an id twice":        {`{"game":"g","goals":[{"id":"a","description":"d","done_when":[{"path":"x","exists":true}]},{"id":"a","description":"d","done_when":[{"path":"x","exists":true}]}]}`, "used twice"},
		"no description":     {`{"game":"g","goals":[{"id":"a","done_when":[{"path":"x","exists":true}]}]}`, "no description"},
		"an empty done_when": {`{"game":"g","goals":[{"id":"a","description":"d","done_when":[]}]}`, "met by anything"},
		"no operator":        {`{"game":"g","goals":[{"id":"a","description":"d","done_when":[{"path":"x"}]}]}`, "no operator"},
		"a bad path":         {`{"game":"g","goals":[{"id":"a","description":"d","done_when":[{"path":"x..y","exists":true}]}]}`, "done_when 1"},
		"two values":         {`{"game":"g","goals":[{"id":"a","description":"d","done_when":[{"path":"x","exists":true}]}]} {}`, "more than one"},
	}
	for name, c := range cases {
		if _, err := Parse(strings.NewReader(c.text)); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: Parse error = %v, want one containing %q", name, err, c.want)
		}
	}
}

func TestCheckAllNamesTheGoalAfterTheLastOneMet(t *testing.T) {
	g := mustParse(t, storyGoals)

	// Two badges, and no longer in Dewford: the goal checked by place fails, and the next goal is still the third badge.
	results, next := g.CheckAll(state(t, `{"location": {"map": "9.11"}, "badges": [1, 2], "badge_count": 2}`))
	if next != 3 || g.Goals[next].ID != "dynamo_badge" {
		t.Fatalf("next = %d, want 3 (dynamo_badge)", next)
	}
	if !results[0].Met || results[1].Met || !results[2].Met || results[3].Met {
		t.Fatalf("results = %+v", results)
	}
	if len(results[3].Failed) != 2 || !strings.Contains(results[3].Failed[0], "a list holding 3") {
		t.Fatalf("the unmet goal's reasons = %q", results[3].Failed)
	}

	// A new game: nothing met, the first goal is next.
	if _, next := g.CheckAll(state(t, `{"location": {"map": "0.9"}, "badges": [], "badge_count": 0}`)); next != 0 {
		t.Fatalf("next on a new game = %d, want 0", next)
	}

	// Every badge: the last goal met, nothing next.
	if _, next := g.CheckAll(state(t, `{"location": {"map": "10.0"}, "badges": [1, 2, 3], "badge_count": 3}`)); next != -1 {
		t.Fatalf("next with the last goal met = %d, want -1", next)
	}
}

func TestAGoalWithAnyExpectationUnmetIsNotMet(t *testing.T) {
	g := mustParse(t, storyGoals)
	r := g.Find("dynamo_badge").Check(state(t, `{"badges": [1, 2, 3]}`))
	if r.Met || len(r.Failed) != 1 || !strings.Contains(r.Failed[0], "badge_count: nothing there") {
		t.Fatalf("Check = %+v", r)
	}
	if g.Find("no_such_goal") != nil {
		t.Fatal("Find found a goal that is not in the file")
	}
}

func TestSizeNote(t *testing.T) {
	dir := t.TempDir()
	small, big := filepath.Join(dir, "small.json"), filepath.Join(dir, "big.json")
	os.WriteFile(small, []byte("{}"), 0o644)
	os.WriteFile(big, make([]byte, KeepUnderBytes+1), 0o644)
	if note := SizeNote(small); note != "" {
		t.Errorf("SizeNote(small) = %q", note)
	}
	if note := SizeNote(big); !strings.Contains(note, "consolidate") {
		t.Errorf("SizeNote(big) = %q", note)
	}
	if note := SizeNote(filepath.Join(dir, "missing.json")); note != "" {
		t.Errorf("SizeNote(missing) = %q", note)
	}
}
