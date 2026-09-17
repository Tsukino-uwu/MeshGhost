// Package skill stores and replays what worked: a skill is one tool call and the rules for what to call next on
// each answer, run by the core with no model between the calls. The model makes one call ("go to that Center,
// fighting whatever stops you") and is asked again only where no rule says what to do.
//
// Every call a skill makes is an ordinary tool call through the same server, so it is validated, logged and
// labelled walked or reached exactly as the model's own would be. The rules read the answers with the scenario
// runner's expectations, so the runner is game-blind and one skill format serves every driver: Emerald's goto and
// battle, TEVI's sequence and reflex.
//
// A skill file is JSON, decoded strictly. It is kept in the knowledge store only after it has succeeded twice
// (the plan's rule): `succeeded` lists both runs, or the skill is marked `draft` while it is being proved.
package skill

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/scenario"
)

// MaxFileBytes bounds a skill file.
const MaxFileBytes = 256 * 1024

// DefaultMaxCalls and MaxMaxCalls bound the calls one skill makes itself; a nested skill counts once in it and
// keeps its own count.
const (
	DefaultMaxCalls = 40
	MaxMaxCalls     = 500
)

// MaxDepth bounds skills calling skills.
const MaxDepth = 4

// Words a rule's then may be instead of a call.
const (
	ThenDone   = "done"   // the skill ends, done
	ThenStop   = "stop"   // the skill ends, stopped on purpose (a whiteout): the rule's note says why
	ThenRepeat = "repeat" // make the skill's own call again
)

// Skill is one skill file.
type Skill struct {
	Name        string `json:"name"`
	Game        string `json:"game"`
	Variant     string `json:"variant,omitempty"`
	Description string `json:"description"`
	// Params names each argument the skill takes and its kind: string, number, bool or any. All are required.
	Params map[string]string `json:"params,omitempty"`
	// Call is made first, and again on repeat.
	Call  Action `json:"call"`
	Rules []Rule `json:"rules"`
	// MaxCalls ends the skill after this many of its own calls.
	MaxCalls int `json:"max_calls,omitempty"`
	// Succeeded names the runs it worked in (a run log and its segment), two at least unless Draft.
	Succeeded []string `json:"succeeded,omitempty"`
	Draft     bool     `json:"draft,omitempty"`
	Note      string   `json:"note,omitempty"`
}

// Action is a tool call or a skill run. A string argument that is exactly "$name" is the skill's argument name.
type Action struct {
	Tool  string         `json:"tool,omitempty"`
	Skill string         `json:"skill,omitempty"`
	Args  map[string]any `json:"args,omitempty"`
}

// Rule says what follows an answer: after the call named After, when every expectation holds, Then.
type Rule struct {
	// After is a tool's name, or skill:<name> for a nested skill's result.
	After string            `json:"after"`
	When  []scenario.Expect `json:"when,omitempty"`
	Then  Then              `json:"then"`
	Note  string            `json:"note,omitempty"`
}

// Then is a word (done, stop, repeat) or an action.
type Then struct {
	Word   string
	Action *Action
}

// UnmarshalJSON reads a word or an action object, strictly.
func (t *Then) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) > 0 && b[0] == '"' {
		return json.Unmarshal(b, &t.Word)
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	var a Action
	if err := dec.Decode(&a); err != nil {
		return err
	}
	t.Action = &a
	return nil
}

// MarshalJSON writes it back as it was read.
func (t Then) MarshalJSON() ([]byte, error) {
	if t.Action != nil {
		return json.Marshal(t.Action)
	}
	return json.Marshal(t.Word)
}

// Name returns what a rule's after calls this action: the tool's name, or skill:<name>.
func (a Action) Name() string {
	if a.Skill != "" {
		return "skill:" + a.Skill
	}
	return a.Tool
}

var (
	namePattern  = regexp.MustCompile(`^[a-z0-9_]{1,64}$`)
	toolPattern  = regexp.MustCompile(`^[a-z_]{1,32}$`)
	paramPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)
	gamePattern  = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
)

// refusedTools are tools a skill may not call, with why.
var refusedTools = map[string]string{
	"run_skill": "a skill runs another skill with {\"skill\": name}",
	"segment":   "a skill is part of the segment it is run in",
}

var paramKinds = map[string]bool{"string": true, "number": true, "bool": true, "any": true}

// Load reads and checks one skill file.
func Load(path string) (*Skill, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	s, err := Parse(io.LimitReader(f, MaxFileBytes+1))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return s, nil
}

// Parse decodes and checks a skill.
func Parse(r io.Reader) (*Skill, error) {
	body, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	if len(body) > MaxFileBytes {
		return nil, fmt.Errorf("over %d bytes", MaxFileBytes)
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	var s Skill
	if err := dec.Decode(&s); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, errors.New("more than one JSON value in the file")
	}
	if err := s.check(); err != nil {
		return nil, err
	}
	return &s, nil
}

func (s *Skill) check() error {
	if !namePattern.MatchString(s.Name) {
		return fmt.Errorf("name must be lowercase letters, digits and _, up to 64: got %q", s.Name)
	}
	if !gamePattern.MatchString(s.Game) {
		return fmt.Errorf("game must name the driver's game: got %q", s.Game)
	}
	if s.Description == "" {
		return errors.New("no description")
	}
	if !s.Draft && len(s.Succeeded) < 2 {
		return errors.New("a skill is kept only once it has succeeded twice: name both runs in succeeded, or mark it draft while proving it")
	}
	if s.MaxCalls == 0 {
		s.MaxCalls = DefaultMaxCalls
	}
	if s.MaxCalls < 1 || s.MaxCalls > MaxMaxCalls {
		return fmt.Errorf("max_calls must be 1 to %d, got %d", MaxMaxCalls, s.MaxCalls)
	}
	for name, kind := range s.Params {
		if !paramPattern.MatchString(name) {
			return fmt.Errorf("param %q: a name is lowercase letters, digits and _", name)
		}
		if !paramKinds[kind] {
			return fmt.Errorf("param %s: kind must be string, number, bool or any, got %q", name, kind)
		}
	}
	if err := s.checkAction("call", s.Call); err != nil {
		return err
	}
	if len(s.Rules) == 0 {
		return errors.New("a skill needs at least one rule, or it is only its call")
	}
	// Every rule must be reachable: its after names the skill's call or an action some rule takes.
	called := map[string]bool{s.Call.Name(): true}
	for i, r := range s.Rules {
		if r.Then.Action != nil {
			called[r.Then.Action.Name()] = true
		}
		if r.Then.Action == nil {
			switch r.Then.Word {
			case ThenDone, ThenStop, ThenRepeat:
			default:
				return fmt.Errorf("rule %d: then must be done, stop, repeat or a call, got %q", i+1, r.Then.Word)
			}
		} else if err := s.checkAction(fmt.Sprintf("rule %d", i+1), *r.Then.Action); err != nil {
			return err
		}
		for j := range r.When {
			if err := r.When[j].Prepare(); err != nil {
				return fmt.Errorf("rule %d: when %d (%s): %w", i+1, j+1, r.When[j].Path, err)
			}
		}
	}
	for i, r := range s.Rules {
		if !called[r.After] {
			return fmt.Errorf("rule %d: after %q names nothing this skill calls", i+1, r.After)
		}
	}
	return nil
}

func (s *Skill) checkAction(where string, a Action) error {
	switch {
	case (a.Tool == "") == (a.Skill == ""):
		return fmt.Errorf("%s: give exactly one of tool and skill", where)
	case a.Tool != "" && !toolPattern.MatchString(a.Tool):
		return fmt.Errorf("%s: tool must be a tool's name, got %q", where, a.Tool)
	case a.Skill != "" && !namePattern.MatchString(a.Skill):
		return fmt.Errorf("%s: skill must be a skill's name, got %q", where, a.Skill)
	}
	if why, refused := refusedTools[a.Tool]; refused {
		return fmt.Errorf("%s: %s is not allowed in a skill: %s", where, a.Tool, why)
	}
	return walkArgs(a.Args, func(ref string) error {
		if _, ok := s.Params[ref]; !ok {
			return fmt.Errorf("%s: $%s is not one of the skill's params", where, ref)
		}
		return nil
	})
}

// walkArgs calls ref for every "$name" string in v.
func walkArgs(v any, ref func(string) error) error {
	switch x := v.(type) {
	case string:
		if name, ok := strings.CutPrefix(x, "$"); ok {
			return ref(name)
		}
	case map[string]any:
		for _, el := range x {
			if err := walkArgs(el, ref); err != nil {
				return err
			}
		}
	case []any:
		for _, el := range x {
			if err := walkArgs(el, ref); err != nil {
				return err
			}
		}
	}
	return nil
}

// substitute copies v with every "$name" string replaced by args[name].
func substitute(v any, args map[string]any) any {
	switch x := v.(type) {
	case string:
		if name, ok := strings.CutPrefix(x, "$"); ok {
			if val, ok := args[name]; ok {
				return val
			}
		}
		return x
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, el := range x {
			out[k] = substitute(el, args)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, el := range x {
			out[i] = substitute(el, args)
		}
		return out
	}
	return v
}

// checkArgs refuses arguments that do not match the skill's params.
func (s *Skill) checkArgs(args map[string]any) error {
	for name := range args {
		if _, ok := s.Params[name]; !ok {
			return fmt.Errorf("skill %s takes no argument %q", s.Name, name)
		}
	}
	for name, kind := range s.Params {
		v, ok := args[name]
		if !ok {
			return fmt.Errorf("skill %s needs the argument %q (%s)", s.Name, name, kind)
		}
		fits := true
		switch kind {
		case "string":
			_, fits = v.(string)
		case "number":
			_, fits = v.(float64)
		case "bool":
			_, fits = v.(bool)
		}
		if !fits {
			return fmt.Errorf("skill %s: argument %q must be a %s, got %v", s.Name, name, kind, v)
		}
	}
	return nil
}

// Dir loads skills from a game's skills folder, checked against the connected game.
type Dir struct {
	Path, Game, Variant string
}

// Load loads the skill name from the folder.
func (d Dir) Load(name string) (*Skill, error) {
	if !namePattern.MatchString(name) {
		return nil, fmt.Errorf("a skill's name is lowercase letters, digits and _: got %q", name)
	}
	s, err := Load(filepath.Join(d.Path, name+".json"))
	if err != nil {
		return nil, err
	}
	if s.Name != name {
		return nil, fmt.Errorf("%s.json names itself %q", name, s.Name)
	}
	if s.Game != d.Game {
		return nil, fmt.Errorf("skill %s is for %s, and the driver is %s", name, s.Game, d.Game)
	}
	if s.Variant != "" && s.Variant != d.Variant {
		return nil, fmt.Errorf("skill %s is for the %s variant, and the driver says %q", name, s.Variant, d.Variant)
	}
	return s, nil
}
