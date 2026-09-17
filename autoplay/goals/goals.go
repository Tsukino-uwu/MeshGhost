// Package goals reads a game's goals file -- the milestones a session plays toward -- and says which of them
// the game's state meets.
//
// A goal is met when every expectation in its done_when holds on an observe answer: the scenario runner's own
// expectations (paths and operators), so a goal is checked the same way a scenario step is and the core stays
// game-blind. Goals are in story order. The next goal is the one after the last goal met, not the first one
// unmet: a goal checked by where the player stands ("in Mauville") stops holding once the player walks on, and
// a later goal met says the earlier ones were passed.
//
// The file is JSON, decoded strictly, like a scenario (phase13.md, 2026-09-16: knowledge files are JSON).
package goals

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/scenario"
)

// MaxFileBytes bounds a goals file.
const MaxFileBytes = 1 << 20

// KeepUnderBytes is the size a knowledge file is kept under (the plan's "about 8 KB"): past it the file is
// consolidated, never grown into a diary. Load does not refuse a larger file; SizeNote says so.
const KeepUnderBytes = 8 * 1024

// File is a game's goals file.
type File struct {
	Game    string `json:"game"`
	Variant string `json:"variant,omitempty"`
	Note    string `json:"note,omitempty"`
	Goals   []Goal `json:"goals"`
}

// Goal is one milestone.
type Goal struct {
	ID          string            `json:"id"`
	Description string            `json:"description"`
	DoneWhen    []scenario.Expect `json:"done_when"`
	// Hints points to where the way is written (a heading of route.md), never the way itself.
	Hints string `json:"hints,omitempty"`
	Note  string `json:"note,omitempty"`
}

// Result is one goal checked against a state.
type Result struct {
	ID          string   `json:"id"`
	Description string   `json:"description"`
	Met         bool     `json:"met"`
	Failed      []string `json:"failed,omitempty"`
	Hints       string   `json:"hints,omitempty"`
}

var idPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

// Load reads and checks a goals file.
func Load(path string) (*File, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	g, err := Parse(io.LimitReader(f, MaxFileBytes+1))
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return g, nil
}

// Parse decodes and checks a goals file.
func Parse(r io.Reader) (*File, error) {
	body, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	if len(body) > MaxFileBytes {
		return nil, fmt.Errorf("over %d bytes", MaxFileBytes)
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	var g File
	if err := dec.Decode(&g); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, errors.New("more than one JSON value in the file")
	}
	if err := g.check(); err != nil {
		return nil, err
	}
	return &g, nil
}

func (g *File) check() error {
	if !idPattern.MatchString(g.Game) {
		return fmt.Errorf("game must name the driver's game (letters, digits, _ or -): got %q", g.Game)
	}
	if len(g.Goals) == 0 {
		return errors.New("a goals file needs at least one goal")
	}
	seen := map[string]bool{}
	for i := range g.Goals {
		goal := &g.Goals[i]
		if !idPattern.MatchString(goal.ID) {
			return fmt.Errorf("goal %d: id must be letters, digits, _ or -, up to 64: got %q", i+1, goal.ID)
		}
		if seen[goal.ID] {
			return fmt.Errorf("goal %d: id %q is used twice", i+1, goal.ID)
		}
		seen[goal.ID] = true
		if goal.Description == "" {
			return fmt.Errorf("goal %s: no description", goal.ID)
		}
		if len(goal.DoneWhen) == 0 {
			return fmt.Errorf("goal %s: done_when is empty, so it would be met by anything", goal.ID)
		}
		for j := range goal.DoneWhen {
			if err := goal.DoneWhen[j].Prepare(); err != nil {
				return fmt.Errorf("goal %s: done_when %d (%s): %w", goal.ID, j+1, goal.DoneWhen[j].Path, err)
			}
		}
	}
	return nil
}

// Find returns the goal with id, or nil.
func (g *File) Find(id string) *Goal {
	for i := range g.Goals {
		if g.Goals[i].ID == id {
			return &g.Goals[i]
		}
	}
	return nil
}

// Check tests one goal against a decoded observe answer.
func (goal *Goal) Check(state any) Result {
	r := Result{ID: goal.ID, Description: goal.Description, Hints: goal.Hints}
	for i := range goal.DoneWhen {
		if why := goal.DoneWhen[i].Check(state); why != "" {
			r.Failed = append(r.Failed, why)
		}
	}
	r.Met = len(r.Failed) == 0
	return r
}

// CheckAll tests every goal, in file order, and returns the index of the next one: the goal after the last one
// met, or -1 when the last goal is met.
func (g *File) CheckAll(state any) ([]Result, int) {
	results := make([]Result, len(g.Goals))
	next := 0
	for i := range g.Goals {
		results[i] = g.Goals[i].Check(state)
		if results[i].Met {
			next = i + 1
		}
	}
	if next == len(g.Goals) {
		next = -1
	}
	return results, next
}

// SizeNote says when a knowledge file has grown past KeepUnderBytes, and "" when it has not or cannot be read.
func SizeNote(path string) string {
	info, err := os.Stat(path)
	if err != nil || info.Size() <= KeepUnderBytes {
		return ""
	}
	return fmt.Sprintf("%s is %d bytes, over the %d a knowledge file is kept under: consolidate it, do not append",
		path, info.Size(), KeepUnderBytes)
}
