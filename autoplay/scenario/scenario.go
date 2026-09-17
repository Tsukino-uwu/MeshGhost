// Package scenario is the runner that replays what an agent explored, with no model: a scenario file
// lists tool calls and what each answer must say, and the runner makes the calls and reports pass or
// fail.
//
// A step is exactly what an agent would call -- a tool name and its arguments -- so the runner goes
// through the same server, the same driver and the same run log as a session does, and a step that
// works here works there. A tracked scenario builds its situation with cheats (the README's "What stays
// out of the repo"): a savestate never enters the repo, so `restore` and `snapshot` are refused.
//
// The file is JSON, decoded strictly: an unknown field is an error, since a misspelled expectation that
// silently checks nothing would pass forever.
package scenario

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"reflect"
	"regexp"
	"strconv"
	"strings"
)

// MaxRepeat bounds how many times one scenario runs in one invocation.
const MaxRepeat = 100

// MaxFileBytes bounds a scenario file.
const MaxFileBytes = 1 << 20

// Scenario is one file.
type Scenario struct {
	Name string `json:"name"`
	// Game and Variant must match the connected driver's hello; Variant may be left out.
	Game    string `json:"game"`
	Variant string `json:"variant,omitempty"`
	// Reproduces names the record this scenario replays: a measurement file, its entry and date.
	Reproduces string `json:"reproduces,omitempty"`
	// Needs says what must be true before it runs that no step makes true (a save loaded, say).
	Needs  string `json:"needs,omitempty"`
	Note   string `json:"note,omitempty"`
	Repeat int    `json:"repeat,omitempty"`
	// Setup makes the situation; Steps are what the scenario is about. The run log labels them as
	// separate segments, so a cheat in Setup never makes the Steps read as reached.
	Setup []Step `json:"setup,omitempty"`
	Steps []Step `json:"steps"`
}

// Step is one tool call and what its answer must say.
type Step struct {
	Tool   string         `json:"tool"`
	Args   map[string]any `json:"args,omitempty"`
	Note   string         `json:"note,omitempty"`
	Expect []Expect       `json:"expect,omitempty"`
	// Error, when set, is text the tool's error must contain: the step expects a refusal.
	Error string `json:"error,omitempty"`
}

// Expect is one check on a value in the answer. Every operator given must hold, and at least one
// must be given.
type Expect struct {
	// Path into the answer: keys and array indices separated by dots ("after.location.x", "log.0.text"),
	// and key[field=value] for the first element of an array whose field reads value
	// ("after.nearby[local_id=3].trainer.range").
	Path      string            `json:"path"`
	Equals    json.RawMessage   `json:"equals,omitempty"`
	NotEquals json.RawMessage   `json:"not_equals,omitempty"`
	OneOf     []json.RawMessage `json:"one_of,omitempty"`
	// Exists false passes only when nothing is at Path.
	Exists *bool    `json:"exists,omitempty"`
	Min    *float64 `json:"min,omitempty"`
	Max    *float64 `json:"max,omitempty"`
	// Contains: a string at Path contains it, or an array at Path has an element equal to it.
	Contains json.RawMessage `json:"contains,omitempty"`
	// ShareOf is a second path: the number at Path is divided by the number there (above 0) before Min and Max,
	// the only operators it takes ("party.0.hp" share_of "party.0.max_hp", max 0.5: at half HP or below).
	ShareOf string `json:"share_of,omitempty"`
	Note    string `json:"note,omitempty"`

	segs, shareSegs []pathSeg
}

var namePattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
var toolPattern = regexp.MustCompile(`^[a-z_]{1,32}$`)

// refusedTools are tools a scenario may not call, with why.
var refusedTools = map[string]string{
	"restore":  "a scenario builds its situation with cheats: a savestate never enters the repo",
	"snapshot": "a scenario builds its situation with cheats: a savestate never enters the repo",
	"segment":  "the runner divides the run log into segments itself",
}

// Load reads and checks one scenario file.
func Load(path string) (*Scenario, error) {
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

// Parse decodes and checks a scenario.
func Parse(r io.Reader) (*Scenario, error) {
	body, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	if len(body) > MaxFileBytes {
		return nil, fmt.Errorf("over %d bytes", MaxFileBytes)
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	var s Scenario
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

func (s *Scenario) check() error {
	if !namePattern.MatchString(s.Name) {
		return fmt.Errorf("name must be letters, digits, _ or -, up to 64: got %q", s.Name)
	}
	if !namePattern.MatchString(s.Game) {
		return fmt.Errorf("game must name the driver's game (letters, digits, _ or -): got %q", s.Game)
	}
	if s.Repeat == 0 {
		s.Repeat = 1
	}
	if s.Repeat < 1 || s.Repeat > MaxRepeat {
		return fmt.Errorf("repeat must be 1 to %d, got %d", MaxRepeat, s.Repeat)
	}
	if len(s.Steps) == 0 {
		return errors.New("a scenario needs at least one step")
	}
	for _, phase := range []struct {
		name string
		list []Step
	}{{"setup", s.Setup}, {"steps", s.Steps}} {
		for i := range phase.list {
			if err := phase.list[i].check(); err != nil {
				return fmt.Errorf("%s %d (%s): %w", phase.name, i+1, phase.list[i].Tool, err)
			}
		}
	}
	return nil
}

func (st *Step) check() error {
	if !toolPattern.MatchString(st.Tool) {
		return fmt.Errorf("tool must be a tool's name, lowercase letters and _: got %q", st.Tool)
	}
	if why, refused := refusedTools[st.Tool]; refused {
		return fmt.Errorf("%s is not allowed in a scenario: %s", st.Tool, why)
	}
	if st.Error != "" && len(st.Expect) > 0 {
		return errors.New("a step expects either an error or checks on its answer, not both")
	}
	for i := range st.Expect {
		if err := st.Expect[i].check(); err != nil {
			return fmt.Errorf("expect %d (%s): %w", i+1, st.Expect[i].Path, err)
		}
	}
	return nil
}

// Prepare checks an expectation read from a file other than a scenario's (a goal's, a skill's) and readies it for
// Check, as loading a scenario does for its own.
func (e *Expect) Prepare() error { return e.check() }

func (e *Expect) check() error {
	segs, err := parsePath(e.Path)
	if err != nil {
		return err
	}
	e.segs = segs
	if e.ShareOf != "" {
		if e.shareSegs, err = parsePath(e.ShareOf); err != nil {
			return fmt.Errorf("share_of: %w", err)
		}
		if e.Min == nil && e.Max == nil {
			return errors.New("share_of needs min or max")
		}
		if e.Equals != nil || e.NotEquals != nil || e.OneOf != nil || e.Exists != nil || e.Contains != nil {
			return errors.New("share_of takes only min and max")
		}
	}
	given := 0
	for _, set := range []bool{e.Equals != nil, e.NotEquals != nil, e.OneOf != nil, e.Exists != nil,
		e.Min != nil, e.Max != nil, e.Contains != nil} {
		if set {
			given++
		}
	}
	if given == 0 {
		return errors.New("no operator: give equals, not_equals, one_of, exists, min, max or contains")
	}
	if e.Exists != nil && !*e.Exists && given > 1 {
		return errors.New("exists false cannot be combined with another operator")
	}
	if e.OneOf != nil && len(e.OneOf) == 0 {
		return errors.New("one_of is empty")
	}
	for _, raw := range append([]json.RawMessage{e.Equals, e.NotEquals, e.Contains}, e.OneOf...) {
		if raw != nil {
			var v any
			if err := json.Unmarshal(raw, &v); err != nil {
				return err
			}
		}
	}
	return nil
}

// pathSeg is one step into a value: a key (or an index, on an array), optionally followed by a filter
// that picks an element of the array found there.
type pathSeg struct {
	key         string
	filter      bool
	field, want string
}

// parsePath splits at dots outside brackets, so a filter's value may hold a dot ("warps[to=0.17]").
func parsePath(p string) ([]pathSeg, error) {
	if p == "" {
		return nil, errors.New("path is empty")
	}
	var segs []pathSeg
	for len(p) > 0 {
		var seg pathSeg
		end := strings.IndexAny(p, ".[")
		if end < 0 {
			end = len(p)
		}
		seg.key = p[:end]
		p = p[end:]
		if strings.HasPrefix(p, "[") {
			shut := strings.IndexByte(p, ']')
			if shut < 0 {
				return nil, errors.New("a [ with no ]")
			}
			field, want, ok := strings.Cut(p[1:shut], "=")
			if !ok || field == "" {
				return nil, fmt.Errorf("a filter is [field=value], got %q", p[:shut+1])
			}
			seg.filter, seg.field, seg.want = true, field, want
			p = p[shut+1:]
		}
		if seg.key == "" && !seg.filter {
			return nil, errors.New("an empty key")
		}
		segs = append(segs, seg)
		if p == "" {
			break
		}
		if p[0] != '.' || len(p) == 1 {
			return nil, fmt.Errorf("expected a dot before %q", p)
		}
		p = p[1:]
	}
	return segs, nil
}

// lookup follows segs into v. ok is false when nothing is there.
func lookup(v any, segs []pathSeg) (any, bool) {
	for _, s := range segs {
		if s.key != "" {
			switch cur := v.(type) {
			case map[string]any:
				next, ok := cur[s.key]
				if !ok {
					return nil, false
				}
				v = next
			case []any:
				i, err := strconv.Atoi(s.key)
				if err != nil || i < 0 || i >= len(cur) {
					return nil, false
				}
				v = cur[i]
			default:
				return nil, false
			}
		}
		if s.filter {
			list, ok := v.([]any)
			if !ok {
				return nil, false
			}
			found := false
			for _, el := range list {
				if obj, ok := el.(map[string]any); ok {
					if fv, ok := obj[s.field]; ok && scalarText(fv) == s.want {
						v, found = el, true
						break
					}
				}
			}
			if !found {
				return nil, false
			}
		}
	}
	return v, true
}

// scalarText is how a filter compares: a string as itself, a number in its shortest form, true, false
// or null; anything else never matches.
func scalarText(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(x)
	case nil:
		return "null"
	}
	return "\x00"
}

// Check tests one expectation against a decoded answer. It returns "" when it holds, or what was wrong.
func (e *Expect) Check(answer any) string {
	got, ok := lookup(answer, e.segs)
	if e.Exists != nil {
		if *e.Exists != ok {
			if ok {
				return fmt.Sprintf("%s: want nothing there, got %s", e.Path, show(got))
			}
			return fmt.Sprintf("%s: want something there, found nothing", e.Path)
		}
		if !ok {
			return ""
		}
	}
	if !ok {
		return fmt.Sprintf("%s: nothing there", e.Path)
	}
	if e.ShareOf != "" {
		n, isNum := got.(float64)
		whole, found := lookup(answer, e.shareSegs)
		d, dNum := whole.(float64)
		if !isNum || !found || !dNum || d <= 0 {
			return fmt.Sprintf("%s share_of %s: want a number over a number above 0, got %s over %s", e.Path, e.ShareOf, show(got), show(whole))
		}
		got = n / d
	}
	if e.Equals != nil {
		if want := decode(e.Equals); !reflect.DeepEqual(got, want) {
			return fmt.Sprintf("%s: want %s, got %s", e.Path, show(want), show(got))
		}
	}
	if e.NotEquals != nil {
		if want := decode(e.NotEquals); reflect.DeepEqual(got, want) {
			return fmt.Sprintf("%s: want anything but %s, got it", e.Path, show(want))
		}
	}
	if e.OneOf != nil {
		hit := false
		var wants []string
		for _, raw := range e.OneOf {
			want := decode(raw)
			wants = append(wants, show(want))
			hit = hit || reflect.DeepEqual(got, want)
		}
		if !hit {
			return fmt.Sprintf("%s: want one of %s, got %s", e.Path, strings.Join(wants, ", "), show(got))
		}
	}
	if e.Min != nil || e.Max != nil {
		n, isNum := got.(float64)
		if !isNum {
			return fmt.Sprintf("%s: want a number, got %s", e.Path, show(got))
		}
		if e.Min != nil && n < *e.Min {
			return fmt.Sprintf("%s: want at least %s, got %s", e.Path, num(*e.Min), num(n))
		}
		if e.Max != nil && n > *e.Max {
			return fmt.Sprintf("%s: want at most %s, got %s", e.Path, num(*e.Max), num(n))
		}
	}
	if e.Contains != nil {
		want := decode(e.Contains)
		switch g := got.(type) {
		case string:
			ws, isStr := want.(string)
			if !isStr || !strings.Contains(g, ws) {
				return fmt.Sprintf("%s: want text containing %s, got %s", e.Path, show(want), show(got))
			}
		case []any:
			hit := false
			for _, el := range g {
				hit = hit || reflect.DeepEqual(el, want)
			}
			if !hit {
				return fmt.Sprintf("%s: want a list holding %s, got %s", e.Path, show(want), show(got))
			}
		default:
			return fmt.Sprintf("%s: contains needs text or a list, got %s", e.Path, show(got))
		}
	}
	return ""
}

// decode reads an operator's value; check has already parsed it once.
func decode(raw json.RawMessage) any {
	var v any
	json.Unmarshal(raw, &v)
	return v
}

// ShowLimit bounds a value quoted in a failure.
const ShowLimit = 200

func show(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	if len(b) > ShowLimit {
		return string(b[:ShowLimit]) + "..."
	}
	return string(b)
}

func num(f float64) string {
	if f == math.Trunc(f) && math.Abs(f) < 1e15 {
		return strconv.FormatInt(int64(f), 10)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}
