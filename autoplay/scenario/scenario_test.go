package scenario

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

const sightScenario = `{
  "name": "sight",
  "game": "fakegame",
  "variant": "vanilla",
  "repeat": 3,
  "setup": [
    {"tool": "cheat", "args": {"kind": "warp", "args": {"map": "0.17", "x": 25, "y": 12}},
     "expect": [{"path": "done", "equals": true}]}
  ],
  "steps": [
    {"tool": "walk", "args": {"direction": "down", "tiles": 1},
     "expect": [{"path": "outcome", "equals": "spotted"}, {"path": "trainer.tiles_away", "equals": 2}]}
  ]
}`

func mustParse(t *testing.T, text string) *Scenario {
	t.Helper()
	s, err := Parse(strings.NewReader(text))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return s
}

func TestParseRefuses(t *testing.T) {
	cases := map[string]struct{ text, want string }{
		"a misspelled operator":           {`{"name":"a","game":"g","steps":[{"tool":"wait","expect":[{"path":"x","equal":1}]}]}`, `unknown field "equal"`},
		"an expectation with no operator": {`{"name":"a","game":"g","steps":[{"tool":"wait","expect":[{"path":"x"}]}]}`, "no operator"},
		"a restore":                       {`{"name":"a","game":"g","steps":[{"tool":"restore","args":{"label":"x"}}]}`, "never enters the repo"},
		"a snapshot":                      {`{"name":"a","game":"g","steps":[{"tool":"snapshot","args":{"label":"x"}}]}`, "never enters the repo"},
		"a segment":                       {`{"name":"a","game":"g","steps":[{"tool":"segment","args":{"label":"x"}}]}`, "segments itself"},
		"no steps":                        {`{"name":"a","game":"g","setup":[{"tool":"wait"}]}`, "at least one step"},
		"no game":                         {`{"name":"a","steps":[{"tool":"wait"}]}`, "game must"},
		"a bad name":                      {`{"name":"a b","game":"g","steps":[{"tool":"wait"}]}`, "name must"},
		"repeat too high":                 {`{"name":"a","game":"g","repeat":101,"steps":[{"tool":"wait"}]}`, "repeat must"},
		"error and expect":                {`{"name":"a","game":"g","steps":[{"tool":"wait","error":"x","expect":[{"path":"x","exists":true}]}]}`, "not both"},
		"exists false and equals":         {`{"name":"a","game":"g","steps":[{"tool":"wait","expect":[{"path":"x","exists":false,"equals":1}]}]}`, "cannot be combined"},
		"an empty one_of":                 {`{"name":"a","game":"g","steps":[{"tool":"wait","expect":[{"path":"x","one_of":[]}]}]}`, "one_of is empty"},
		"two documents":                   {`{"name":"a","game":"g","steps":[{"tool":"wait"}]} {}`, "more than one"},
		"a bad tool name":                 {`{"name":"a","game":"g","steps":[{"tool":"Wait"}]}`, "tool must"},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := Parse(strings.NewReader(c.text))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("Parse = %v, want an error containing %q", err, c.want)
			}
		})
	}
}

func TestParseDefaultsRepeatToOne(t *testing.T) {
	s := mustParse(t, `{"name":"a","game":"g","steps":[{"tool":"wait","args":{"frames":1}}]}`)
	if s.Repeat != 1 {
		t.Fatalf("Repeat = %d, want 1", s.Repeat)
	}
}

func TestParsePathRefuses(t *testing.T) {
	for _, p := range []string{"", ".a", "a.", "a..b", "a[", "a[x]", "a[=1]", "a[x=1]b"} {
		if _, err := parsePath(p); err == nil {
			t.Errorf("parsePath(%q) = nil error, want one", p)
		}
	}
}

func TestLookup(t *testing.T) {
	var answer any
	json.Unmarshal([]byte(`{
	  "after": {"location": {"map": "0.17", "x": 25},
	            "nearby": [{"local_id": 2, "x": 33}, {"local_id": 3, "x": 25, "trainer": {"range": 2}}],
	            "warps": [{"to": "1.0", "x": 7}]},
	  "log": [{"text": "first"}, {"text": "second"}],
	  "0": "a key that reads as a number"
	}`), &answer)
	cases := []struct {
		path string
		want any
		ok   bool
	}{
		{"after.location.map", "0.17", true},
		{"after.location.x", 25.0, true},
		{"log.1.text", "second", true},
		{"log.2.text", nil, false},
		{"after.nearby[local_id=3].trainer.range", 2.0, true},
		{"after.nearby[local_id=4].x", nil, false},
		{"after.warps[to=1.0].x", 7.0, true},
		{"0", "a key that reads as a number", true},
		{"after.location.x.y", nil, false},
		{"after.missing", nil, false},
	}
	for _, c := range cases {
		segs, err := parsePath(c.path)
		if err != nil {
			t.Fatalf("parsePath(%q): %v", c.path, err)
		}
		got, ok := lookup(answer, segs)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("lookup(%q) = %v, %v; want %v, %v", c.path, got, ok, c.want, c.ok)
		}
	}
}

func TestCheckOperators(t *testing.T) {
	var answer any
	json.Unmarshal([]byte(`{"n": 2, "s": "spotted", "b": false, "z": null, "list": ["A", 3], "obj": {"k": [1, 2]}}`), &answer)
	cases := []struct {
		expect string
		fails  string // "" when it holds, else text the reason contains
	}{
		{`{"path":"n","equals":2}`, ""},
		{`{"path":"n","equals":3}`, "n: want 3, got 2"},
		{`{"path":"s","equals":"spotted"}`, ""},
		{`{"path":"s","equals":"done"}`, `want "done", got "spotted"`},
		{`{"path":"b","equals":false}`, ""},
		{`{"path":"z","equals":null}`, ""},
		{`{"path":"obj","equals":{"k":[1,2]}}`, ""},
		{`{"path":"n","not_equals":3}`, ""},
		{`{"path":"n","not_equals":2}`, "anything but 2"},
		{`{"path":"s","one_of":["done","spotted"]}`, ""},
		{`{"path":"s","one_of":["done","blocked"]}`, `one of "done", "blocked"`},
		{`{"path":"n","exists":true}`, ""},
		{`{"path":"missing","exists":true}`, "found nothing"},
		{`{"path":"missing","exists":false}`, ""},
		{`{"path":"z","exists":false}`, "want nothing there, got null"},
		{`{"path":"n","min":2,"max":2}`, ""},
		{`{"path":"n","min":3}`, "at least 3, got 2"},
		{`{"path":"n","max":1.5}`, "at most 1.5, got 2"},
		{`{"path":"s","min":1}`, "want a number"},
		{`{"path":"s","contains":"pot"}`, ""},
		{`{"path":"s","contains":"xyz"}`, "text containing"},
		{`{"path":"list","contains":3}`, ""},
		{`{"path":"list","contains":"B"}`, "a list holding"},
		{`{"path":"n","contains":2}`, "needs text or a list"},
		{`{"path":"missing","equals":1}`, "missing: nothing there"},
	}
	for _, c := range cases {
		var e Expect
		if err := json.Unmarshal([]byte(c.expect), &e); err != nil {
			t.Fatalf("%s: %v", c.expect, err)
		}
		if err := e.check(); err != nil {
			t.Fatalf("%s: check: %v", c.expect, err)
		}
		got := e.Check(answer)
		if (c.fails == "") != (got == "") || !strings.Contains(got, c.fails) {
			t.Errorf("%s: Check = %q, want %q", c.expect, got, c.fails)
		}
	}
}

// fakeCaller answers from a function and records every call.
type fakeCaller struct {
	calls  []string
	answer func(tool string, args map[string]any) (string, bool, error)
}

func (f *fakeCaller) Call(_ context.Context, tool string, args map[string]any) (string, bool, error) {
	f.calls = append(f.calls, tool)
	return f.answer(tool, args)
}

// gameAnswers is a driver on fakegame whose walk answers spotted two tiles away, behind a server whose
// segment tool labels a segment reached when a cheat ran in it.
func gameAnswers(game string) func(string, map[string]any) (string, bool, error) {
	cheated := false
	return func(tool string, _ map[string]any) (string, bool, error) {
		switch tool {
		case "status":
			return `{"connected":true,"driver":{"game":"` + game + `","variant":"vanilla"}}`, false, nil
		case "segment":
			claim := "walked"
			if cheated {
				claim = "reached"
			}
			cheated = false
			return `{"closed":{"claim":"` + claim + `"}}`, false, nil
		case "cheat":
			cheated = true
			return `{"done":true}`, false, nil
		case "walk":
			return `{"outcome":"spotted","moved":1,"trainer":{"local_id":3,"tiles_away":2}}`, false, nil
		}
		return "no such tool " + tool, true, nil
	}
}

func TestRunPassesEveryRepeat(t *testing.T) {
	s := mustParse(t, sightScenario)
	c := &fakeCaller{answer: gameAnswers("fakegame")}
	var out bytes.Buffer
	rep, err := Run(context.Background(), c, s, Options{Out: &out})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !rep.OK() || rep.Passed != 3 || len(rep.Runs) != 3 {
		t.Fatalf("report = %+v\n%s", rep, out.String())
	}
	for _, r := range rep.Runs {
		if r.StepsClaim != "walked" {
			t.Errorf("run %d: steps claim %q, want walked (the cheat was in setup)", r.N, r.StepsClaim)
		}
	}
	if !strings.Contains(out.String(), "sight: PASS, 3 of 3") {
		t.Errorf("output lacks the verdict:\n%s", out.String())
	}
}

func TestRunFailsOnABrokenExpectation(t *testing.T) {
	broken := strings.Replace(sightScenario, `tiles_away", "equals": 2`, `tiles_away", "equals": 3`, 1)
	if broken == sightScenario {
		t.Fatal("the replacement did not apply")
	}
	s := mustParse(t, broken)

	c := &fakeCaller{answer: gameAnswers("fakegame")}
	rep, err := Run(context.Background(), c, s, Options{})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if rep.OK() || len(rep.Runs) != 1 {
		t.Fatalf("report = %+v, want one failed run and a stop", rep)
	}
	f := rep.Runs[0].Failure
	if f == nil || f.Phase != "steps" || f.Step != 1 || f.Tool != "walk" || f.Reason != "trainer.tiles_away: want 3, got 2" {
		t.Fatalf("failure = %+v", f)
	}

	c = &fakeCaller{answer: gameAnswers("fakegame")}
	rep, _ = Run(context.Background(), c, s, Options{All: true})
	if len(rep.Runs) != 3 || rep.Passed != 0 {
		t.Fatalf("with All: report = %+v, want three failed runs", rep)
	}
}

func TestRunStopsAtAFailedSetup(t *testing.T) {
	s := mustParse(t, sightScenario)
	answers := gameAnswers("fakegame")
	c := &fakeCaller{answer: func(tool string, args map[string]any) (string, bool, error) {
		if tool == "cheat" {
			return "warp refused: not in the overworld", true, nil
		}
		return answers(tool, args)
	}}
	rep, err := Run(context.Background(), c, s, Options{})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	f := rep.Runs[0].Failure
	if f == nil || f.Phase != "setup" || !strings.Contains(f.Reason, "warp refused") {
		t.Fatalf("failure = %+v", f)
	}
	for _, call := range c.calls {
		if call == "walk" {
			t.Fatal("a step ran after its setup failed")
		}
	}
}

func TestRunExpectedErrors(t *testing.T) {
	s := mustParse(t, `{"name":"refusal","game":"fakegame","steps":[{"tool":"goto","error":"needs the overworld"}]}`)
	answers := gameAnswers("fakegame")
	refuse := &fakeCaller{answer: func(tool string, args map[string]any) (string, bool, error) {
		if tool == "goto" {
			return "goto needs the overworld", true, nil
		}
		return answers(tool, args)
	}}
	if rep, err := Run(context.Background(), refuse, s, Options{}); err != nil || !rep.OK() {
		t.Fatalf("an expected refusal: report %+v, err %v", rep, err)
	}
	other := &fakeCaller{answer: func(tool string, args map[string]any) (string, bool, error) {
		if tool == "goto" {
			return "no driver is connected", true, nil
		}
		return answers(tool, args)
	}}
	if rep, _ := Run(context.Background(), other, s, Options{}); rep.OK() {
		t.Fatal("a different error passed as the expected one")
	}
	answered := &fakeCaller{answer: func(tool string, args map[string]any) (string, bool, error) {
		if tool == "goto" {
			return `{"outcome":"done"}`, false, nil
		}
		return answers(tool, args)
	}}
	if rep, _ := Run(context.Background(), answered, s, Options{}); rep.OK() {
		t.Fatal("a step that expected a refusal passed when the tool answered")
	}
}

func TestRunRefusesWhatIsNotConnected(t *testing.T) {
	s := mustParse(t, sightScenario)
	cases := map[string]string{
		"another game":    `{"connected":true,"driver":{"game":"crystal","variant":"vanilla"}}`,
		"another variant": `{"connected":true,"driver":{"game":"fakegame","variant":"archipelago"}}`,
		"no driver":       `{"connected":false}`,
	}
	for name, status := range cases {
		t.Run(name, func(t *testing.T) {
			c := &fakeCaller{answer: func(tool string, _ map[string]any) (string, bool, error) {
				if tool == "status" {
					return status, false, nil
				}
				t.Errorf("%s was called after status", tool)
				return "", true, nil
			}}
			rep, err := Run(context.Background(), c, s, Options{})
			if !errors.Is(err, ErrRefused) || len(rep.Runs) != 0 {
				t.Fatalf("Run = %+v, %v; want ErrRefused and no runs", rep, err)
			}
		})
	}
}

func TestRunReturnsALinkFailure(t *testing.T) {
	s := mustParse(t, sightScenario)
	answers := gameAnswers("fakegame")
	gone := errors.New("the session closed")
	c := &fakeCaller{answer: func(tool string, args map[string]any) (string, bool, error) {
		if tool == "walk" {
			return "", false, gone
		}
		return answers(tool, args)
	}}
	rep, err := Run(context.Background(), c, s, Options{})
	if !errors.Is(err, gone) || rep.OK() {
		t.Fatalf("Run = %+v, %v; want the link's error", rep, err)
	}
}
