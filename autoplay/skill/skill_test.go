package skill

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// trip is the scratch loop the Emerald story sessions ran (2026-09-17), as rules.
const trip = `{
  "name": "trip", "game": "emerald", "description": "goto, fighting and reading whatever stops it",
  "params": {"map": "string", "x": "number", "y": "number"},
  "call": {"tool": "goto", "args": {"map": "$map", "x": "$x", "y": "$y", "run": true}},
  "rules": [
    {"after": "goto", "when": [{"path": "outcome", "equals": "done"}], "then": "done"},
    {"after": "goto", "when": [{"path": "outcome", "one_of": ["spotted", "left_overworld"]}], "then": {"tool": "battle", "args": {"policy": "effective"}}},
    {"after": "goto", "when": [{"path": "outcome", "equals": "dialogue_open"}], "then": {"tool": "advance_text"}},
    {"after": "advance_text", "when": [{"path": "outcome", "equals": "battle_started"}], "then": {"tool": "battle", "args": {"policy": "effective"}}},
    {"after": "advance_text", "when": [{"path": "outcome", "equals": "closed"}], "then": "repeat"},
    {"after": "battle", "when": [{"path": "outcome_raw", "equals": 2}], "then": "stop", "note": "a whiteout"},
    {"after": "battle", "when": [{"path": "outcome", "equals": "no_battle"}], "then": {"tool": "advance_text"}},
    {"after": "battle", "when": [{"path": "outcome", "equals": "ended"}], "then": "repeat"}
  ],
  "max_calls": 12,
  "succeeded": ["run a: segment 1", "run b: segment 2"]
}`

// healFirst heals when HP is at half or below, then trips.
const healFirst = `{
  "name": "heal_first", "game": "emerald", "description": "heal when low, then trip",
  "params": {"map": "string", "x": "number", "y": "number"},
  "call": {"tool": "observe"},
  "rules": [
    {"after": "observe", "when": [{"path": "party.0.hp", "share_of": "party.0.max_hp", "max": 0.5}], "then": {"tool": "talk", "args": {"local_id": 1}}},
    {"after": "observe", "then": {"skill": "trip", "args": {"map": "$map", "x": "$x", "y": "$y"}}},
    {"after": "talk", "then": {"skill": "trip", "args": {"map": "$map", "x": "$x", "y": "$y"}}},
    {"after": "skill:trip", "when": [{"path": "outcome", "equals": "done"}], "then": "done"}
  ],
  "draft": true
}`

type loader map[string]string

func (l loader) Load(name string) (*Skill, error) {
	text, ok := l[name]
	if !ok {
		return nil, fmt.Errorf("no skill %q", name)
	}
	return Parse(strings.NewReader(text))
}

// script answers each tool from a queue of answers, and records the calls and their arguments.
type script struct {
	answers map[string][]string
	calls   []string
	args    []map[string]any
}

func (s *script) Call(_ context.Context, tool string, args map[string]any) (string, bool, error) {
	s.calls = append(s.calls, tool)
	s.args = append(s.args, args)
	q := s.answers[tool]
	if len(q) == 0 {
		return "", false, errors.New("the script has no answer left for " + tool)
	}
	s.answers[tool] = q[1:]
	if strings.HasPrefix(q[0], "ERROR ") {
		return strings.TrimPrefix(q[0], "ERROR "), true, nil
	}
	return q[0], false, nil
}

var tools = map[string]bool{"goto": true, "battle": true, "advance_text": true, "observe": true, "talk": true}

func run(t *testing.T, sc *script, name string, args map[string]any) Result {
	t.Helper()
	rn := Runner{Caller: sc, Skills: loader{"trip": trip, "heal_first": healFirst}, Tools: tools}
	res, err := rn.Run(context.Background(), name, args)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return res
}

var tripArgs = map[string]any{"map": "10.5", "x": 7.0, "y": 4.0}

func TestTripFollowsTheChainToDone(t *testing.T) {
	sc := &script{answers: map[string][]string{
		"goto":         {`{"outcome":"spotted"}`, `{"outcome":"dialogue_open"}`, `{"outcome":"done"}`},
		"battle":       {`{"outcome":"ended","outcome_raw":1}`, `{"outcome":"ended","outcome_raw":1}`},
		"advance_text": {`{"outcome":"battle_started"}`},
	}}
	res := run(t, sc, "trip", tripArgs)
	want := "goto battle goto advance_text battle goto"
	if res.Outcome != OutcomeDone || strings.Join(sc.calls, " ") != want || res.Calls != 6 {
		t.Fatalf("outcome %s, calls %v (%d); want done, %s", res.Outcome, sc.calls, res.Calls, want)
	}
	if sc.args[0]["map"] != "10.5" || sc.args[0]["x"] != 7.0 || sc.args[0]["run"] != true {
		t.Fatalf("goto's arguments = %v", sc.args[0])
	}
	if len(res.Trail) != 6 || res.Trail[0].Outcome != "spotted" || res.Trail[0].Rule != 2 || res.Trail[5].Rule != 1 {
		t.Fatalf("trail = %+v", res.Trail)
	}
	if res.OutcomeWord() != "done" {
		t.Fatal("OutcomeWord is not the outcome")
	}
}

func TestTripStopsOnAWhiteout(t *testing.T) {
	sc := &script{answers: map[string][]string{
		"goto":   {`{"outcome":"left_overworld"}`},
		"battle": {`{"outcome":"ended","outcome_raw":2}`},
	}}
	res := run(t, sc, "trip", tripArgs)
	if res.Outcome != OutcomeStopped || res.Reason != "a whiteout" || res.LastCall != "battle" {
		t.Fatalf("result = %+v", res)
	}
}

func TestAnAnswerNoRuleCoversEndsForTheCaller(t *testing.T) {
	sc := &script{answers: map[string][]string{"goto": {`{"outcome":"unreachable","reason":"no way on foot"}`}}}
	res := run(t, sc, "trip", tripArgs)
	last, _ := res.Last.(map[string]any)
	if res.Outcome != OutcomeNoRule || last["reason"] != "no way on foot" || res.Calls != 1 {
		t.Fatalf("result = %+v", res)
	}
}

func TestMaxCallsEndsARunThatWouldGoOn(t *testing.T) {
	goes := make([]string, 20)
	battles := make([]string, 20)
	for i := range goes {
		goes[i], battles[i] = `{"outcome":"left_overworld"}`, `{"outcome":"ended","outcome_raw":4}`
	}
	sc := &script{answers: map[string][]string{"goto": goes, "battle": battles}}
	res := run(t, sc, "trip", tripArgs)
	if res.Outcome != OutcomeMaxCalls || res.Calls != 12 || len(sc.calls) != 12 {
		t.Fatalf("result = %+v after %d calls", res, len(sc.calls))
	}
}

func TestARuleStopsDecidingAtItsMax(t *testing.T) {
	looping := strings.Replace(trip, `"then": "repeat"},`, `"then": "repeat", "max": 2},`, 1)
	goes, reads := make([]string, 10), make([]string, 10)
	for i := range goes {
		goes[i], reads[i] = `{"outcome":"dialogue_open"}`, `{"outcome":"closed"}`
	}
	sc := &script{answers: map[string][]string{"goto": goes, "advance_text": reads}}
	res, err := Runner{Caller: sc, Skills: loader{"trip": looping}, Tools: tools}.Run(context.Background(), "trip", tripArgs)
	if err != nil {
		t.Fatal(err)
	}
	// goto, read, repeat; goto, read, repeat; goto, read -- and the third closed matches rule 5 past its max.
	if res.Outcome != OutcomeNoRule || strings.Join(sc.calls, " ") != "goto advance_text goto advance_text goto advance_text" ||
		!strings.Contains(res.Reason, "rule 5 matched and had decided its max 2 times") {
		t.Fatalf("result = %+v, calls %v", res, sc.calls)
	}
}

func TestAnAnswerMarkedALoopEndsTheRun(t *testing.T) {
	sc := &script{answers: map[string][]string{
		"goto":         {`{"outcome":"dialogue_open"}`, `{"loop":{"tool":"goto","repeats":3,"note":"goto answered the same here 3 times"},"outcome":"dialogue_open"}`},
		"advance_text": {`{"outcome":"closed"}`},
	}}
	res := run(t, sc, "trip", tripArgs)
	if res.Outcome != OutcomeLoop || res.Reason != "goto answered the same here 3 times" || res.Calls != 3 ||
		len(res.Trail) != 3 || res.Trail[2].Rule != 0 {
		t.Fatalf("result = %+v, calls %v", res, sc.calls)
	}
}

func TestAToolErrorEndsTheRun(t *testing.T) {
	sc := &script{answers: map[string][]string{"goto": {`ERROR the connected driver does not support "goto"`}}}
	res := run(t, sc, "trip", tripArgs)
	if res.Outcome != OutcomeToolError || !strings.Contains(fmt.Sprint(res.Last), "does not support") || !res.Trail[0].Error {
		t.Fatalf("result = %+v", res)
	}
}

func TestANestedSkillAndShareOf(t *testing.T) {
	low := `{"party":[{"hp":20,"max_hp":60}]}`
	sc := &script{answers: map[string][]string{
		"observe": {low},
		"talk":    {`{"outcome":"closed"}`},
		"goto":    {`{"outcome":"done"}`},
	}}
	res := run(t, sc, "heal_first", tripArgs)
	if res.Outcome != OutcomeDone || strings.Join(sc.calls, " ") != "observe talk goto" || res.Calls != 3 || !res.Draft {
		t.Fatalf("result = %+v, calls %v", res, sc.calls)
	}
	if sc.args[2]["map"] != "10.5" {
		t.Fatalf("the nested skill's goto got %v", sc.args[2])
	}

	sc = &script{answers: map[string][]string{"observe": {`{"party":[{"hp":50,"max_hp":60}]}`}, "goto": {`{"outcome":"done"}`}}}
	if res := run(t, sc, "heal_first", tripArgs); res.Outcome != OutcomeDone || strings.Join(sc.calls, " ") != "observe goto" {
		t.Fatalf("with HP above half: %+v, calls %v", res, sc.calls)
	}
}

func TestParseRefuses(t *testing.T) {
	base := func(edit func(map[string]any)) string {
		var m map[string]any
		json.Unmarshal([]byte(trip), &m)
		edit(m)
		b, _ := json.Marshal(m)
		return string(b)
	}
	rule := func(r map[string]any) func(map[string]any) {
		return func(m map[string]any) { m["rules"] = append(m["rules"].([]any), r) }
	}
	cases := map[string]struct{ text, want string }{
		"one success, not a draft": {base(func(m map[string]any) { m["succeeded"] = []string{"one"} }), "succeeded twice"},
		"an unknown field":         {base(func(m map[string]any) { m["rule"] = 1 }), "unknown field"},
		"an unknown field in then": {base(rule(map[string]any{"after": "goto", "then": map[string]any{"tool": "wait", "arg": 1}})), "unknown field"},
		"an unknown word":          {base(rule(map[string]any{"after": "goto", "then": "again"})), `got "again"`},
		"after naming nothing":     {base(rule(map[string]any{"after": "walk", "then": "done"})), `after "walk" names nothing`},
		"an undeclared $param":     {base(rule(map[string]any{"after": "goto", "then": map[string]any{"tool": "wait", "args": map[string]any{"frames": "$n"}}})), "$n is not one of"},
		"run_skill":                {base(rule(map[string]any{"after": "goto", "then": map[string]any{"tool": "run_skill"}})), "not allowed in a skill"},
		"both tool and skill":      {base(rule(map[string]any{"after": "goto", "then": map[string]any{"tool": "wait", "skill": "x"}})), "exactly one of"},
		"a bad param kind":         {base(func(m map[string]any) { m["params"] = map[string]any{"x": "int"} }), "kind must be"},
		"no rules":                 {base(func(m map[string]any) { m["rules"] = []any{} }), "at least one rule"},
		"max_calls too high":       {base(func(m map[string]any) { m["max_calls"] = MaxMaxCalls + 1 }), "max_calls must be"},
		"a negative max":           {base(rule(map[string]any{"after": "goto", "then": "done", "max": -1})), "max must be"},
		"a bad expectation":        {base(rule(map[string]any{"after": "goto", "when": []any{map[string]any{"path": "x"}}, "then": "done"})), "no operator"},
	}
	for name, c := range cases {
		if _, err := Parse(strings.NewReader(c.text)); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: Parse error = %v, want one containing %q", name, err, c.want)
		}
	}
}

func TestRunRefusesBeforeItsFirstCall(t *testing.T) {
	cases := map[string]struct {
		skills loader
		tools  map[string]bool
		args   map[string]any
		want   string
	}{
		"a tool the server lacks": {loader{"trip": trip}, map[string]bool{"goto": true}, tripArgs, `calls "battle", which the server does not have`},
		"a missing argument":      {loader{"trip": trip}, tools, map[string]any{"map": "10.5", "x": 7.0}, `needs the argument "y"`},
		"an extra argument":       {loader{"trip": trip}, tools, map[string]any{"map": "10.5", "x": 7.0, "y": 4.0, "z": 1.0}, `no argument "z"`},
		"a wrong kind":            {loader{"trip": trip}, tools, map[string]any{"map": 10.5, "x": 7.0, "y": 4.0}, `"map" must be a string`},
		"a missing nested skill":  {loader{"heal_first": healFirst}, tools, tripArgs, `no skill "trip"`},
		"skills too deep":         {deepLoader(), tools, map[string]any{}, "deeper than"},
	}
	for name, c := range cases {
		sc := &script{answers: map[string][]string{}}
		name0 := "trip"
		if name == "a missing nested skill" {
			name0 = "heal_first"
		}
		if name == "skills too deep" {
			name0 = "d0"
		}
		_, err := Runner{Caller: sc, Skills: c.skills, Tools: c.tools}.Run(context.Background(), name0, c.args)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: Run error = %v, want one containing %q", name, err, c.want)
		}
		if len(sc.calls) != 0 {
			t.Errorf("%s: calls were made before the refusal: %v", name, sc.calls)
		}
	}
}

// deepLoader is d0 calling d1 calling ... past MaxDepth.
func deepLoader() loader {
	l := loader{}
	for i := 0; i <= MaxDepth; i++ {
		l[fmt.Sprintf("d%d", i)] = fmt.Sprintf(`{"name":"d%d","game":"g","description":"d","call":{"skill":"d%d"},"rules":[{"after":"skill:d%d","then":"done"}],"draft":true}`, i, i+1, i+1)
	}
	return l
}

func TestDirLoadChecksTheFileAgainstTheGame(t *testing.T) {
	dir := t.TempDir()
	write := func(name, text string) {
		t.Helper()
		if err := writeFile(dir, name+".json", text); err != nil {
			t.Fatal(err)
		}
	}
	write("trip", trip)
	write("misnamed", trip)
	if _, err := (Dir{Path: dir, Game: "emerald", Variant: "vanilla"}).Load("trip"); err != nil {
		t.Fatalf("Load(trip): %v", err)
	}
	if _, err := (Dir{Path: dir, Game: "crystal"}).Load("trip"); err == nil || !strings.Contains(err.Error(), "is for emerald") {
		t.Fatalf("another game's skill: %v", err)
	}
	if _, err := (Dir{Path: dir, Game: "emerald"}).Load("misnamed"); err == nil || !strings.Contains(err.Error(), `names itself "trip"`) {
		t.Fatalf("a misnamed file: %v", err)
	}
	if _, err := (Dir{Path: dir, Game: "emerald"}).Load("../trip"); err == nil {
		t.Fatal("a name with a path in it was loaded")
	}
}

func writeFile(dir, name, text string) error {
	return os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644)
}
