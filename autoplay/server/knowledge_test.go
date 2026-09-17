package server

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withGames gives the harness's server a games folder holding one goals file for fakegame.
func withGames(t *testing.T, goalsJSON string) func(*Options) {
	t.Helper()
	dir := t.TempDir()
	if goalsJSON != "" {
		if err := os.MkdirAll(filepath.Join(dir, "fakegame"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "fakegame", GoalsFile), []byte(goalsJSON), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return func(o *Options) { o.GamesDir = dir }
}

const fakeGoals = `{"game": "fakegame", "goals": [
  {"id": "first_badge", "description": "one badge", "done_when": [{"path": "badges", "contains": 1}]},
  {"id": "second_badge", "description": "two badges", "done_when": [{"path": "badges", "contains": 2}], "hints": "route.md#two"}
]}`

// readLog returns the run log's records.
func readLog(t *testing.T, path string) []map[string]any {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out []map[string]any
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var rec map[string]any
		if err := json.Unmarshal(sc.Bytes(), &rec); err != nil {
			t.Fatalf("a record that does not parse: %q", sc.Text())
		}
		out = append(out, rec)
	}
	return out
}

func TestGoalChecksTheGoalsFileAgainstObserve(t *testing.T) {
	h := newHarness(t, withGames(t, fakeGoals))
	observes := 0
	h.startDriver(t, []string{"observe"}, func(verb string, _ json.RawMessage) (string, any) {
		observes++
		return "result", map[string]any{"badges": []int{1}}
	})

	text, isErr := h.call(t, "goal", map[string]any{})
	if isErr {
		t.Fatalf("goal = %s", text)
	}
	var out GoalOut
	if err := json.Unmarshal([]byte(text), &out); err != nil {
		t.Fatalf("%v: %s", err, text)
	}
	if out.AllMet || len(out.Goals) != 2 || !out.Goals[0].Met || out.Goals[1].Met {
		t.Fatalf("goal = %s", text)
	}
	if out.Next == nil || out.Next.ID != "second_badge" || out.Next.Hints != "route.md#two" || len(out.Next.Failed) != 1 {
		t.Fatalf("next = %+v", out.Next)
	}

	text, isErr = h.call(t, "goal", map[string]any{"id": "first_badge"})
	out = GoalOut{}
	if isErr || json.Unmarshal([]byte(text), &out) != nil || out.Goal == nil || out.Goal.ID != "first_badge" || !out.Goal.Met ||
		len(out.Goals) != 0 || out.Next == nil || out.Next.ID != "second_badge" {
		t.Fatalf("goal first_badge = %s (error %v)", text, isErr)
	}
	if observes != 2 {
		t.Fatalf("observes = %d, want one per goal call", observes)
	}

	if text, isErr := h.call(t, "goal", map[string]any{"id": "third_badge"}); !isErr || !strings.Contains(text, `no goal "third_badge"`) {
		t.Fatalf("an unknown goal = %s (error %v)", text, isErr)
	}
	if observes != 2 {
		t.Fatal("an unknown goal still observed")
	}
	if got := h.log.Current().Claim; got != "walked" {
		t.Fatalf("goal marked the segment %q", got)
	}
}

func TestGoalAnswersAllMet(t *testing.T) {
	h := newHarness(t, withGames(t, fakeGoals))
	h.startDriver(t, []string{"observe"}, func(string, json.RawMessage) (string, any) {
		return "result", map[string]any{"badges": []int{1, 2}}
	})
	text, isErr := h.call(t, "goal", map[string]any{})
	if isErr || !strings.Contains(text, `"all_met":true`) || strings.Contains(text, `"next"`) {
		t.Fatalf("goal = %s (error %v)", text, isErr)
	}
}

func TestGoalRefusesAMissingOrForeignFile(t *testing.T) {
	h := newHarness(t, withGames(t, ""))
	h.startDriver(t, []string{"observe"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	if text, isErr := h.call(t, "goal", map[string]any{}); !isErr || !strings.Contains(text, "the goals file") {
		t.Fatalf("goal with no file = %s (error %v)", text, isErr)
	}

	h = newHarness(t, withGames(t, strings.Replace(fakeGoals, `"game": "fakegame"`, `"game": "othergame"`, 1)))
	h.startDriver(t, []string{"observe"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	if text, isErr := h.call(t, "goal", map[string]any{}); !isErr || !strings.Contains(text, "is for othergame") {
		t.Fatalf("goal with another game's file = %s (error %v)", text, isErr)
	}
}

func TestSnapshotAppendsToTheIndex(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"snapshot", "cheat:warp"}, func(verb string, payload json.RawMessage) (string, any) {
		var p struct {
			Path string `json:"path"`
		}
		json.Unmarshal(payload, &p)
		if verb == "snapshot" {
			os.WriteFile(filepath.FromSlash(p.Path), []byte("state"), 0o644)
		}
		return "result", map[string]any{}
	})

	if text, isErr := h.call(t, "snapshot", map[string]any{"label": "walked_here", "note": "the gym door"}); isErr {
		t.Fatalf("snapshot = %s", text)
	}
	h.call(t, "cheat", map[string]any{"kind": "warp"})
	if text, isErr := h.call(t, "snapshot", map[string]any{"label": "warped_here"}); isErr {
		t.Fatalf("snapshot = %s", text)
	}
	if text, isErr := h.call(t, "snapshot", map[string]any{"label": "long", "note": strings.Repeat("x", MaxNoteBytes+1)}); !isErr {
		t.Fatalf("a note over the cap was taken: %s", text)
	}

	f, err := os.Open(filepath.Join(h.states, "fakegame", IndexFile))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var entries []IndexEntry
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var e IndexEntry
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			t.Fatalf("%v: %q", err, sc.Text())
		}
		entries = append(entries, e)
	}
	if len(entries) != 2 {
		t.Fatalf("index entries = %+v", entries)
	}
	if entries[0].Label != "walked_here" || entries[0].Note != "the gym door" || entries[0].Segment.Claim != "walked" ||
		entries[0].RunLog != filepath.Base(h.log.Path()) {
		t.Fatalf("first entry = %+v", entries[0])
	}
	if entries[1].Label != "warped_here" || entries[1].Segment.Claim != "reached" || entries[1].Segment.Because[0] != "cheat:warp" {
		t.Fatalf("second entry = %+v", entries[1])
	}
}

func TestTheRunLogKeepsAnAnswersOutcome(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"walk", "observe"}, func(verb string, _ json.RawMessage) (string, any) {
		if verb == "walk" {
			return "result", map[string]any{"outcome": "spotted", "moved": 1}
		}
		return "result", map[string]any{"outcome": map[string]any{"not": "a word"}}
	})
	h.call(t, "walk", map[string]any{"direction": "up", "tiles": 2})
	h.call(t, "observe", map[string]any{})
	h.call(t, "walk", map[string]any{"direction": "sideways", "tiles": 2})

	var calls []map[string]any
	for _, rec := range readLog(t, h.log.Path()) {
		if rec["type"] == "call" {
			calls = append(calls, rec)
		}
	}
	if len(calls) != 3 {
		t.Fatalf("calls = %v", calls)
	}
	if calls[0]["outcome"] != "spotted" {
		t.Errorf("walk's record = %v", calls[0])
	}
	if _, has := calls[1]["outcome"]; has {
		t.Errorf("an outcome that is not a word was kept: %v", calls[1])
	}
	if _, has := calls[2]["outcome"]; has || calls[2]["ok"] != false {
		t.Errorf("a refused call's record = %v", calls[2])
	}
}

// withSkills gives the harness's server a games folder holding fakegame's skills.
func withSkills(t *testing.T, skills map[string]string) func(*Options) {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "fakegame", SkillsDir), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, text := range skills {
		if err := os.WriteFile(filepath.Join(dir, "fakegame", SkillsDir, name+".json"), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return func(o *Options) { o.GamesDir = dir }
}

const fakeTrip = `{"name": "trip", "game": "fakegame", "description": "goto, fighting what spots it",
  "params": {"x": "number"},
  "call": {"tool": "goto", "args": {"x": "$x", "y": 3}},
  "rules": [
    {"after": "goto", "when": [{"path": "outcome", "equals": "done"}], "then": "done"},
    {"after": "goto", "when": [{"path": "outcome", "equals": "spotted"}], "then": {"tool": "battle", "args": {"policy": "effective"}}},
    {"after": "battle", "when": [{"path": "outcome", "equals": "ended"}], "then": "repeat"}
  ],
  "draft": true}`

func TestRunSkillMakesEachCallThroughTheServer(t *testing.T) {
	h := newHarness(t, withSkills(t, map[string]string{"trip": fakeTrip}))
	gotos := 0
	var gotoArgs []string
	h.startDriver(t, []string{"goto", "battle"}, func(verb string, payload json.RawMessage) (string, any) {
		switch verb {
		case "goto":
			gotos++
			gotoArgs = append(gotoArgs, string(payload))
			if gotos == 1 {
				return "result", map[string]any{"outcome": "spotted"}
			}
			return "result", map[string]any{"outcome": "done"}
		case "battle":
			return "result", map[string]any{"outcome": "ended", "outcome_raw": 1}
		}
		return "error", map[string]any{"message": "unexpected " + verb}
	})

	text, isErr := h.call(t, "run_skill", map[string]any{"name": "trip", "args": map[string]any{"x": 7}})
	if isErr {
		t.Fatalf("run_skill = %s", text)
	}
	var res struct {
		Outcome string `json:"outcome"`
		Calls   int    `json:"calls"`
		Draft   bool   `json:"draft"`
	}
	if err := json.Unmarshal([]byte(text), &res); err != nil || res.Outcome != "done" || res.Calls != 3 || !res.Draft {
		t.Fatalf("run_skill = %s", text)
	}
	if len(gotoArgs) != 2 || !strings.Contains(gotoArgs[0], `"x":7`) || !strings.Contains(gotoArgs[0], `"y":3`) {
		t.Fatalf("the driver's goto payloads = %v", gotoArgs)
	}

	var logged []string
	for _, rec := range readLog(t, h.log.Path()) {
		if rec["type"] == "call" {
			logged = append(logged, fmt.Sprintf("%v:%v", rec["tool"], rec["outcome"]))
		}
	}
	if want := "goto:spotted battle:ended goto:done run_skill:done"; strings.Join(logged, " ") != want {
		t.Fatalf("the run log's calls = %v, want %s", logged, want)
	}
	if got := h.log.Current().Claim; got != "walked" {
		t.Fatalf("a skill of play marked the segment %q", got)
	}

	// A skill that cannot run is refused before any call reaches the driver.
	if text, isErr := h.call(t, "run_skill", map[string]any{"name": "trip", "args": map[string]any{"x": "seven"}}); !isErr || !strings.Contains(text, `"x" must be a number`) {
		t.Fatalf("wrong arguments = %s (error %v)", text, isErr)
	}
	if text, isErr := h.call(t, "run_skill", map[string]any{"name": "fly"}); !isErr || !strings.Contains(text, "fly.json") {
		t.Fatalf("a missing skill = %s (error %v)", text, isErr)
	}
	if gotos != 2 {
		t.Fatalf("a refused skill reached the driver: %d gotos", gotos)
	}
}

func TestRunSkillRefusesAToolTheServerLacks(t *testing.T) {
	h := newHarness(t, withSkills(t, map[string]string{"trip": strings.ReplaceAll(fakeTrip, `"battle"`, `"fly"`)}))
	h.startDriver(t, []string{"goto"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{"outcome": "done"} })
	if text, isErr := h.call(t, "run_skill", map[string]any{"name": "trip", "args": map[string]any{"x": 1}}); !isErr || !strings.Contains(text, `"fly", which the server does not have`) {
		t.Fatalf("run_skill = %s (error %v)", text, isErr)
	}
}
