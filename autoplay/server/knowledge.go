package server

// The knowledge store's side of the core (Phase 3): the goal tool, which checks a game's goals file against an
// observe, and the snapshot index. What a goal or an index entry says about the game is never read here: a goal's
// expectations are paths and operators into the driver's answer, as a scenario step's are.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/driver"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/goals"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/runlog"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/scenario"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/skill"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// GoalsFile is a game's goals file in its folder under the games folder.
const GoalsFile = "goals.json"

// gameDir is the connected game's folder under the games folder.
func (t *tools) gameDir() (string, driver.Hello, error) {
	hello, ok := t.hub.Current()
	if !ok {
		return "", hello, driver.ErrNoDriver
	}
	if !labelPattern.MatchString(hello.Game) {
		return "", hello, fmt.Errorf("the driver's game name %q cannot be a folder name", hello.Game)
	}
	return filepath.Join(t.gamesDir, hello.Game), hello, nil
}

// GoalIn is the goal tool's input.
type GoalIn struct {
	ID string `json:"id,omitempty" jsonschema:"a goal's id as the goals file names it; omitted, every goal and the next one"`
}

// GoalOut is the goal tool's answer.
type GoalOut struct {
	Game string `json:"game"`
	// Goal is the goal asked for by id.
	Goal *goals.Result `json:"goal,omitempty"`
	// Goals is every goal's id and whether it is met, when no id was given.
	Goals []GoalBrief `json:"goals,omitempty"`
	// Next is the goal after the last one met, with why it is not met yet; absent when the last goal is met.
	Next     *goals.Result `json:"next,omitempty"`
	AllMet   bool          `json:"all_met"`
	SizeNote string        `json:"size_note,omitempty"`
}

// GoalBrief is one goal in the list.
type GoalBrief struct {
	ID  string `json:"id"`
	Met bool   `json:"met"`
}

func (t *tools) goal(ctx context.Context, _ *mcp.CallToolRequest, in GoalIn) (*mcp.CallToolResult, GoalOut, error) {
	out := GoalOut{}
	dir, hello, err := t.gameDir()
	if err != nil {
		return nil, out, err
	}
	out.Game = hello.Game
	path := filepath.Join(dir, GoalsFile)
	file, err := goals.Load(path)
	if err != nil {
		return nil, out, fmt.Errorf("the goals file: %w", err)
	}
	if file.Game != hello.Game {
		return nil, out, fmt.Errorf("%s is for %s, and the driver is %s", path, file.Game, hello.Game)
	}
	if file.Variant != "" && file.Variant != hello.Variant {
		return nil, out, fmt.Errorf("%s is for the %s variant, and the driver says %q", path, file.Variant, hello.Variant)
	}
	if in.ID != "" && file.Find(in.ID) == nil {
		return nil, out, fmt.Errorf("no goal %q in %s", in.ID, path)
	}

	raw, err := t.forward(ctx, "observe", "observe", struct{}{}, CallTimeout)
	if err != nil {
		return nil, out, err
	}
	var state any
	if err := json.Unmarshal(raw, &state); err != nil {
		return nil, out, fmt.Errorf("the driver's observe does not parse: %w", err)
	}
	results, next := file.CheckAll(state)
	out.AllMet = next == -1
	if next >= 0 {
		out.Next = &results[next]
	}
	for i := range results {
		if in.ID != "" && results[i].ID == in.ID {
			out.Goal = &results[i]
		}
		if in.ID == "" {
			out.Goals = append(out.Goals, GoalBrief{ID: results[i].ID, Met: results[i].Met})
		}
	}
	out.SizeNote = goals.SizeNote(path)
	return nil, out, nil
}

// IndexFile is the snapshot index in a game's states folder: one JSON line per snapshot taken, gitignored with the
// snapshots it lists.
const IndexFile = "index.ndjson"

// IndexEntry is one line of the snapshot index.
type IndexEntry struct {
	Label string    `json:"label"`
	At    time.Time `json:"at"`
	Note  string    `json:"note,omitempty"`
	// RunLog and Segment say where the snapshot was taken, and whether what led to it was walked or reached.
	RunLog  string          `json:"run_log,omitempty"`
	Segment *runlog.Segment `json:"segment,omitempty"`
}

// MaxNoteBytes bounds a snapshot's note.
const MaxNoteBytes = 500

// indexSnapshot appends a snapshot just written to its game's index. A failure to write the index does not undo the
// snapshot; the answer says so.
func (t *tools) indexSnapshot(statePath, label, note string) error {
	e := IndexEntry{Label: label, At: time.Now(), Note: note}
	if t.log != nil {
		seg := t.log.Current()
		e.RunLog, e.Segment = filepath.Base(t.log.Path()), &seg
	}
	line, err := json.Marshal(e)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(filepath.Dir(statePath), IndexFile), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(line, '\n'))
	return err
}

// SkillsDir is a game's skills folder, beside its goals file.
const SkillsDir = "skills"

// RunSkillIn is the run_skill tool's input.
type RunSkillIn struct {
	Name string         `json:"name" jsonschema:"the skill's name, its file in the game's skills folder without .json"`
	Args map[string]any `json:"args,omitempty" jsonschema:"the skill's arguments, as its params name them"`
}

// self is a client session on this same server, made once: a skill's calls go through it, so each is validated
// against its tool's schema and logged exactly as the model's own call would be.
func (t *tools) self() (*mcp.ClientSession, error) {
	t.selfOnce.Do(func() {
		ctx := context.Background()
		serverT, clientT := mcp.NewInMemoryTransports()
		if _, err := t.server.Connect(ctx, serverT, nil); err != nil {
			t.selfErr = fmt.Errorf("a session for skills: %w", err)
			return
		}
		t.selfSession, t.selfErr = mcp.NewClient(&mcp.Implementation{Name: "autoplay-skills", Version: "1"}, nil).Connect(ctx, clientT, nil)
	})
	return t.selfSession, t.selfErr
}

func (t *tools) runSkill(ctx context.Context, _ *mcp.CallToolRequest, in RunSkillIn) (*mcp.CallToolResult, skill.Result, error) {
	dir, hello, err := t.gameDir()
	if err != nil {
		return nil, skill.Result{}, err
	}
	session, err := t.self()
	if err != nil {
		return nil, skill.Result{}, err
	}
	known := map[string]bool{}
	for tool, err := range session.Tools(ctx, nil) {
		if err != nil {
			return nil, skill.Result{}, fmt.Errorf("list tools: %w", err)
		}
		known[tool.Name] = true
	}
	rn := skill.Runner{
		Caller: scenario.SessionCaller{Session: session},
		Skills: skill.Dir{Path: filepath.Join(dir, SkillsDir), Game: hello.Game, Variant: hello.Variant},
		Tools:  known,
	}
	res, err := rn.Run(ctx, in.Name, in.Args)
	return nil, res, err
}
