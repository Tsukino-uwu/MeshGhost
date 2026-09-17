// Package server is the MCP face of the core: the tools an agent calls, each one either answered
// by the core itself or forwarded to the connected driver.
//
// A tool that needs the game checks the driver's announced capabilities first, so a driver that
// cannot do a thing produces a plain refusal rather than a call it will fail. Everything a driver
// returns is passed through unread: the core stays game-blind.
package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/driver"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/runlog"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// CallTimeout is the base time a driver gets to answer; input that runs for frames gets more.
const CallTimeout = 10 * time.Second

// MaxPressFrames bounds one press: a long hold is a leg, and legs end on the game's state.
const MaxPressFrames = 600

// Options are what the server needs besides the hub. A zero Options is valid: no run log, snapshots
// under "states", and no exec.
type Options struct {
	Log       *runlog.Log
	StatesDir string
	// ExecToken is this session's token (WriteExecToken); exec refuses while it is empty.
	ExecToken string
}

// New builds the MCP server over a hub.
func New(hub *driver.Hub, version string, opts Options) *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "autoplay", Version: version}, nil)
	if opts.StatesDir == "" {
		opts.StatesDir = "states"
	}
	t := &tools{hub: hub, log: opts.Log, statesDir: opts.StatesDir, execToken: opts.ExecToken}

	mcp.AddTool(s, &mcp.Tool{
		Name: "status",
		Description: "Whether a game driver is connected, and what it says about itself: host, game, " +
			"variant, build, the capabilities it supports and the savestate slots it protects. " +
			"Call this first in a session.",
	}, logged(t, "status", nil, t.status))

	mcp.AddTool(s, &mcp.Tool{
		Name: "observe",
		Description: "A snapshot of the game as the driver reads it from memory (position, map, " +
			"whatever the driver supports). Every name in it comes from the driver.",
	}, logged(t, "observe", nil, t.observe))

	mcp.AddTool(s, &mcp.Tool{
		Name: "press",
		Description: "Hold buttons for a number of frames, then release. The raw escape hatch: " +
			"prefer a tool that ends on the game's own state when the driver has one. " +
			"Returns what the driver saw change.",
	}, logged(t, "press", nil, t.press))

	mcp.AddTool(s, &mcp.Tool{
		Name: "sequence",
		Description: "Play a timeline of inputs in one go, frame-exact, the way a player's hands overlap: each step " +
			"holds its buttons from frame `from` (counted from the sequence's first frame) for `frames`, and steps may " +
			"overlap (run right for 90 frames while Jump is held from 30 to 44). With stop_on (event kinds, as events " +
			"names them), the first such event the driver reports ends the sequence early: what is held is let go on " +
			"the next frame and nothing later starts. Returns what changed, the frames run and the event it stopped on.",
	}, logged(t, "sequence", nil, t.sequence))

	mcp.AddTool(s, &mcp.Tool{
		Name: "wait",
		Description: "Let frames pass with no input at all, then return what changed. Use this to " +
			"wait -- never hold a button to wait, since every button does something somewhere.",
	}, logged(t, "wait", nil, t.wait))

	mcp.AddTool(s, &mcp.Tool{
		Name: "select",
		Description: "Choose an entry in the menu that is open now. The driver reads the menu from the " +
			"game, presses toward the entry one step at a time until the game's own cursor is on it, " +
			"then presses confirm and waits for the menu to respond -- never press-and-hope. Name the " +
			"entry by its text as observe's menu.items shows it (item, case does not matter) or by its " +
			"0-based index; confirm false stops with the cursor on it. Returns what changed.",
	}, logged(t, "select", nil, t.selectEntry))

	mcp.AddTool(s, &mcp.Tool{
		Name: "walk",
		Description: "Move the player a number of tiles in one direction, holding it the whole way, each " +
			"tile counted on the game's own state rather than a frame count. Stops early and says why: " +
			"blocked (with what is on the refused tile), map_changed (a warp or a map edge), " +
			"spotted (a trainer has begun coming: answer with battle), dialogue_open, menu_open, " +
			"left_overworld. Returns the tiles moved and what changed. " +
			"run: true runs where the save can; walk for precision, run for speed.",
	}, logged(t, "walk", nil, t.walk))

	mcp.AddTool(s, &mcp.Tool{
		Name: "goto",
		Description: "Move the player to a tile on this map by a planned route: straight legs, turning at " +
			"speed, replanning around what refuses a step, and crossing an unbeaten trainer's line only " +
			"where there is no other way (route_in_sight names them). Rides whatever the player is on " +
			"(on foot, run: true to run). With map, a tile on another map: the driver plans the maps " +
			"between by their warps and edges, crosses each, and plans the tile route on each map it " +
			"arrives on (maps lists them). Stops early and says why, as walk does, or unreachable (with " +
			"the reason). Returns where it ended, the tiles moved, turns and replans.",
	}, logged(t, "goto", nil, t.gotoTile))

	mcp.AddTool(s, &mcp.Tool{
		Name: "battle",
		Description: "Play the battle on screen to its end in one call, a trainer's words before and after " +
			"included, so call it straight after a spotted. policy strongest (default) fights with the " +
			"usable move of most power times accuracy; effective weighs that by the game's type chart " +
			"against the foe and the same-type bonus, where the game module measured them; " +
			"run runs. forget strong_variety answers a question to learn a move -- keeping strong damaging moves of " +
			"different types, status moves going first, and saying no when the new move is worth least; " +
			"without it battle stops needs_choice there. Returns a log of every message and choice, and ends ended, needs_choice (a menu it " +
			"will not answer) or stuck (with what it was waiting on) -- within seconds of nothing changing.",
	}, logged(t, "battle", nil, t.battle))

	mcp.AddTool(s, &mcp.Tool{
		Name: "advance_text",
		Description: "Press through the message on screen, box by box. Stops when it closes, when a menu " +
			"opens (answer it with select), when a battle begins (use battle), or stuck. Returns a log of " +
			"every box.",
	}, logged(t, "advance_text", nil, t.advanceText))

	mcp.AddTool(s, &mcp.Tool{
		Name: "talk",
		Description: "Talk to a character on this map: go to a tile beside it by a planned route (as goto), " +
			"face it, press A, and press through what it says (as advance_text). local_id names it (nearby " +
			"lists them); omitted, the nearest. Returns the log of every box and ends as advance_text does " +
			"(closed, menu_open, battle_started, ...), or as goto does if the walk there stopped early.",
	}, logged(t, "talk", nil, t.talk))

	mcp.AddTool(s, &mcp.Tool{
		Name: "type_text",
		Description: "Type text on the on-screen keyboard the game shows (a naming screen): the driver clears what " +
			"is typed, then for each character changes page, moves the game's own cursor to its key one step at a " +
			"time and presses it, reading each result back, and with confirm (default true) chooses OK. observe's " +
			"keyboard lists the keys. Returns what was typed as the game read it.",
	}, logged(t, "type_text", nil, t.typeText))

	mcp.AddTool(s, &mcp.Tool{
		Name: "set_clock",
		Description: "Set the clock on the game's clock screen (a new game's wall clock) to hours (0-23) and minutes " +
			"the way a player does: the driver holds the hands' direction, whichever way round is shorter, and lets " +
			"go on the frame the game reads the time, then with confirm (default true) answers the game's question " +
			"YES. observe's clock shows the time and state. Returns the time set.",
	}, logged(t, "set_clock", nil, t.setClock))

	mcp.AddTool(s, &mcp.Tool{
		Name: "screenshot",
		Description: "A picture of the game frame, saved under dev-scripts/shots/<game>/ and returned " +
			"as an image. The navigation sense: what is around, what a thing is, which entry is " +
			"highlighted. Never proof of anything visual.",
	}, logged(t, "screenshot", nil, t.screenshot))

	mcp.AddTool(s, &mcp.Tool{
		Name:        "events",
		Description: "Events the driver reported since a sequence number (0 for everything buffered).",
	}, logged(t, "events", nil, t.events))

	mcp.AddTool(s, &mcp.Tool{
		Name: "snapshot",
		Description: "Save the game's whole state to a named file under the core's states folder " +
			"(gitignored, never committed). Never a numbered slot: slots belong to people.",
	}, logged(t, "snapshot", nil, t.snapshot))

	mcp.AddTool(s, &mcp.Tool{
		Name: "restore",
		Description: "Load a named snapshot. Marks the current segment REACHED: what follows no " +
			"longer shows that a player can get here.",
	}, logged(t, "restore", func(RestoreIn) string { return "restore" }, t.restore))

	mcp.AddTool(s, &mcp.Tool{
		Name: "cheat",
		Description: "Change the game by other means than play: a kind the driver announced as " +
			"cheat:<kind> (status lists them), with that kind's arguments. Marks the current " +
			"segment REACHED. Make the situation with a cheat, then let the game run the thing " +
			"being tested through ordinary input.",
	}, logged(t, "cheat", func(in CheatIn) string { return "cheat:" + in.Kind }, t.cheat))

	mcp.AddTool(s, &mcp.Tool{
		Name: "exec",
		Description: "Run code inside the game's host (Lua in BizHawk) and return what it returns and prints. " +
			"The escape hatch for a question no tool answers yet: read or write memory, call the host's API. " +
			"Marks the current segment REACHED, since the code may change the game. Carries this core's " +
			"session token, which the driver checks against the token file the core wrote.",
	}, logged(t, "exec", func(ExecIn) string { return "exec" }, t.exec))

	mcp.AddTool(s, &mcp.Tool{
		Name: "segment",
		Description: "Close the current run segment and start a new one with a label. Returns the " +
			"closed segment, labelled walked or reached by what happened in it.",
	}, logged(t, "segment", nil, t.segment))

	return s
}

type tools struct {
	hub       *driver.Hub
	log       *runlog.Log
	statesDir string
	execToken string

	// The cheats still in effect as the driver last said, for the connection it said it on.
	persistMu    sync.Mutex
	persistGen   uint64
	persistKinds []string
}

// logged wraps a handler so every call lands in the run log. reachedBy, when given, names what a
// SUCCESSFUL call did to the world by other means than play.
func logged[In, Out any](t *tools, name string, reachedBy func(In) string, h mcp.ToolHandlerFor[In, Out]) mcp.ToolHandlerFor[In, Out] {
	return func(ctx context.Context, req *mcp.CallToolRequest, in In) (*mcp.CallToolResult, Out, error) {
		res, out, err := h(ctx, req, in)
		by := ""
		if reachedBy != nil {
			by = reachedBy(in)
		}
		t.log.Call(name, in, err, by)
		// A call made while a cheat is still in effect belongs to a segment that cheat reaches, whenever it began.
		for _, on := range t.stillOn() {
			t.log.InEffect(on)
		}
		return res, out, err
	}
}

// StatusOut is the status tool's answer.
type StatusOut struct {
	Connected   bool          `json:"connected"`
	Driver      *driver.Hello `json:"driver,omitempty"`
	NewestEvent uint64        `json:"newest_event"`
}

func (t *tools) status(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, StatusOut, error) {
	out := StatusOut{}
	if hello, ok := t.hub.Current(); ok {
		out.Connected = true
		out.Driver = &hello
	}
	_, out.NewestEvent = t.hub.EventsSince(0)
	return nil, out, nil
}

func (t *tools) observe(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, any, error) {
	raw, err := t.forward(ctx, "observe", "observe", struct{}{}, CallTimeout)
	return nil, raw, err
}

// PressIn is the press tool's input.
type PressIn struct {
	Buttons []string `json:"buttons" jsonschema:"button names the driver accepts, e.g. A, B, Start, Up"`
	Frames  int      `json:"frames" jsonschema:"how many frames to hold them, 1 to 600"`
}

func (t *tools) press(ctx context.Context, _ *mcp.CallToolRequest, in PressIn) (*mcp.CallToolResult, any, error) {
	if len(in.Buttons) == 0 {
		return nil, nil, fmt.Errorf("press needs at least one button")
	}
	if in.Frames < 1 || in.Frames > MaxPressFrames {
		return nil, nil, fmt.Errorf("frames must be 1 to %d, got %d", MaxPressFrames, in.Frames)
	}
	// A driver answers after the hold ends; allow for a slow host (20 fps) on top of the base.
	timeout := CallTimeout + time.Duration(in.Frames)*50*time.Millisecond
	raw, err := t.forward(ctx, "press", "press", in, timeout)
	return nil, raw, err
}

// MaxSequenceFrames bounds a sequence's length, MaxSequenceSteps its steps and MaxStopOn its stop_on kinds.
const (
	MaxSequenceFrames = 1800
	MaxSequenceSteps  = 64
	MaxStopOn         = 16
)

// SequenceStep is one hold in a sequence.
type SequenceStep struct {
	Buttons []string `json:"buttons" jsonschema:"button names the driver accepts, as press takes them"`
	From    int      `json:"from" jsonschema:"the frame the hold begins, counted from the sequence's first frame (0)"`
	Frames  int      `json:"frames" jsonschema:"how many frames to hold, 1 to 600"`
}

// SequenceIn is the sequence tool's input.
type SequenceIn struct {
	Steps  []SequenceStep `json:"steps" jsonschema:"the holds, in any order; they may overlap"`
	StopOn []string       `json:"stop_on,omitempty" jsonschema:"event kinds that end the sequence early, e.g. damage_taken"`
}

func (t *tools) sequence(ctx context.Context, _ *mcp.CallToolRequest, in SequenceIn) (*mcp.CallToolResult, any, error) {
	if len(in.Steps) == 0 || len(in.Steps) > MaxSequenceSteps {
		return nil, nil, fmt.Errorf("a sequence has 1 to %d steps, got %d", MaxSequenceSteps, len(in.Steps))
	}
	end := 0
	for i, st := range in.Steps {
		if len(st.Buttons) == 0 {
			return nil, nil, fmt.Errorf("step %d holds no button", i)
		}
		if st.Frames < 1 || st.Frames > MaxPressFrames {
			return nil, nil, fmt.Errorf("step %d: frames must be 1 to %d, got %d", i, MaxPressFrames, st.Frames)
		}
		if st.From < 0 || st.From+st.Frames > MaxSequenceFrames {
			return nil, nil, fmt.Errorf("step %d: from %d plus %d frames is outside 0 to %d", i, st.From, st.Frames, MaxSequenceFrames)
		}
		end = max(end, st.From+st.Frames)
	}
	if len(in.StopOn) > MaxStopOn {
		return nil, nil, fmt.Errorf("stop_on names at most %d kinds, got %d", MaxStopOn, len(in.StopOn))
	}
	for _, k := range in.StopOn {
		if k == "" || len(k) > 64 {
			return nil, nil, fmt.Errorf("a stop_on kind is 1 to 64 bytes, got %q", k)
		}
	}
	timeout := CallTimeout + time.Duration(end)*50*time.Millisecond
	raw, err := t.forward(ctx, "sequence", "sequence", in, timeout)
	return nil, raw, err
}

// MaxWaitFrames bounds one wait.
const MaxWaitFrames = 3600

// WaitIn is the wait tool's input.
type WaitIn struct {
	Frames int `json:"frames" jsonschema:"how many frames to let pass, 1 to 3600"`
}

func (t *tools) wait(ctx context.Context, _ *mcp.CallToolRequest, in WaitIn) (*mcp.CallToolResult, any, error) {
	if in.Frames < 1 || in.Frames > MaxWaitFrames {
		return nil, nil, fmt.Errorf("frames must be 1 to %d, got %d", MaxWaitFrames, in.Frames)
	}
	timeout := CallTimeout + time.Duration(in.Frames)*50*time.Millisecond
	raw, err := t.forward(ctx, "wait", "wait", in, timeout)
	return nil, raw, err
}

// SelectIn is the select tool's input: exactly one of Item and Index.
type SelectIn struct {
	Item    string `json:"item,omitempty" jsonschema:"the entry's text as observe's menu.items shows it; case does not matter"`
	Index   *int   `json:"index,omitempty" jsonschema:"the entry's 0-based position in menu.items, instead of item"`
	Confirm *bool  `json:"confirm,omitempty" jsonschema:"press confirm once the cursor is on the entry; default true"`
}

// selectRequest is what the driver receives: confirm is always spelled out.
type selectRequest struct {
	Item    string `json:"item,omitempty"`
	Index   *int   `json:"index,omitempty"`
	Confirm bool   `json:"confirm"`
}

// SelectTimeout allows for a cursor walked across a long menu one step at a time.
const SelectTimeout = CallTimeout + 30*time.Second

func (t *tools) selectEntry(ctx context.Context, _ *mcp.CallToolRequest, in SelectIn) (*mcp.CallToolResult, any, error) {
	if (in.Item != "") == (in.Index != nil) {
		return nil, nil, fmt.Errorf("select needs exactly one of item and index")
	}
	if len(in.Item) > 64 {
		return nil, nil, fmt.Errorf("an item is at most 64 bytes, got %d", len(in.Item))
	}
	if in.Index != nil && (*in.Index < 0 || *in.Index > 255) {
		return nil, nil, fmt.Errorf("index must be 0 to 255, got %d", *in.Index)
	}
	req := selectRequest{Item: in.Item, Index: in.Index, Confirm: in.Confirm == nil || *in.Confirm}
	raw, err := t.forward(ctx, "select", "select", req, SelectTimeout)
	return nil, raw, err
}

// MaxWalkTiles bounds one walk: a longer route is several, or a goto once there is one.
const MaxWalkTiles = 32

// WalkIn is the walk tool's input.
type WalkIn struct {
	Direction string `json:"direction" jsonschema:"up, down, left or right"`
	Tiles     int    `json:"tiles" jsonschema:"how many tiles, 1 to 32"`
	Run       bool   `json:"run,omitempty" jsonschema:"hold the run button too; the answer's ran says whether the game ran"`
}

func (t *tools) walk(ctx context.Context, _ *mcp.CallToolRequest, in WalkIn) (*mcp.CallToolResult, any, error) {
	switch in.Direction {
	case "up", "down", "left", "right":
	default:
		return nil, nil, fmt.Errorf(`direction must be "up", "down", "left" or "right", got %q`, in.Direction)
	}
	if in.Tiles < 1 || in.Tiles > MaxWalkTiles {
		return nil, nil, fmt.Errorf("tiles must be 1 to %d, got %d", MaxWalkTiles, in.Tiles)
	}
	// A tile takes well under a second; allow for a slow host and a warp at the end.
	timeout := CallTimeout + time.Duration(in.Tiles)*2*time.Second
	raw, err := t.forward(ctx, "walk", "walk", in, timeout)
	return nil, raw, err
}

// MaxGotoCoordinate bounds a goto target; the driver checks it against the map itself.
const MaxGotoCoordinate = 1023

// GotoTimeout allows a long route on foot: the driver bounds the ride itself in frames.
const GotoTimeout = CallTimeout + 3*time.Minute

// GotoMapsTimeout allows a route across several maps.
const GotoMapsTimeout = CallTimeout + 10*time.Minute

// MaxMapName bounds the map a goto names; the driver reads it, the core does not.
const MaxMapName = 32

// GotoIn is the goto tool's input.
type GotoIn struct {
	X          int    `json:"x" jsonschema:"the target tile's x on its map"`
	Y          int    `json:"y" jsonschema:"the target tile's y on its map"`
	Map        string `json:"map,omitempty" jsonschema:"the target's map as observe names it (location.map); omitted, this map"`
	Run        bool   `json:"run,omitempty" jsonschema:"run where on foot"`
	CrossGrass bool   `json:"cross_grass,omitempty" jsonschema:"route through tall grass freely, as with a Repel running; by default the route avoids it where it can"`
}

func (t *tools) gotoTile(ctx context.Context, _ *mcp.CallToolRequest, in GotoIn) (*mcp.CallToolResult, any, error) {
	if in.X < 0 || in.Y < 0 || in.X > MaxGotoCoordinate || in.Y > MaxGotoCoordinate {
		return nil, nil, fmt.Errorf("x and y must be 0 to %d, got %d,%d", MaxGotoCoordinate, in.X, in.Y)
	}
	if len(in.Map) > MaxMapName {
		return nil, nil, fmt.Errorf("map must be at most %d bytes", MaxMapName)
	}
	timeout := GotoTimeout
	if in.Map != "" {
		timeout = GotoMapsTimeout
	}
	raw, err := t.forward(ctx, "goto", "goto", in, timeout)
	return nil, raw, err
}

// BattleTimeout allows a long battle: the driver ends a stuck one within seconds on its own.
const BattleTimeout = CallTimeout + 10*time.Minute

// BattleIn is the battle tool's input.
type BattleIn struct {
	Policy string `json:"policy,omitempty" jsonschema:"strongest (default), effective or run"`
	Forget string `json:"forget,omitempty" jsonschema:"strong_variety answers a learn-a-move question; absent stops needs_choice there"`
}

func (t *tools) battle(ctx context.Context, _ *mcp.CallToolRequest, in BattleIn) (*mcp.CallToolResult, any, error) {
	switch in.Policy {
	case "", "strongest", "effective", "run":
	default:
		return nil, nil, fmt.Errorf(`policy must be "strongest", "effective" or "run", got %q`, in.Policy)
	}
	switch in.Forget {
	case "", "strong_variety":
	default:
		return nil, nil, fmt.Errorf(`forget must be "strong_variety" or absent, got %q`, in.Forget)
	}
	raw, err := t.forward(ctx, "battle", "battle", in, BattleTimeout)
	return nil, raw, err
}

func (t *tools) advanceText(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, any, error) {
	raw, err := t.forward(ctx, "advance_text", "advance_text", struct{}{}, CallTimeout+3*time.Minute)
	return nil, raw, err
}

// TalkIn is the talk tool's input.
type TalkIn struct {
	LocalID *int `json:"local_id,omitempty" jsonschema:"the character's local_id as nearby lists it; omitted, the nearest"`
}

func (t *tools) talk(ctx context.Context, _ *mcp.CallToolRequest, in TalkIn) (*mcp.CallToolResult, any, error) {
	if in.LocalID != nil && (*in.LocalID < 0 || *in.LocalID > 0xFFFF) {
		return nil, nil, fmt.Errorf("local_id must be 0 to 65535, got %d", *in.LocalID)
	}
	raw, err := t.forward(ctx, "talk", "talk", in, GotoTimeout+3*time.Minute)
	return nil, raw, err
}

// MaxTypeTextBytes bounds the text for type_text; a game's keyboard bounds it further.
const MaxTypeTextBytes = 64

// TypeTextIn is the type_text tool's input.
type TypeTextIn struct {
	Text    string `json:"text" jsonschema:"the characters to type, as observe's keyboard keys show them"`
	Confirm *bool  `json:"confirm,omitempty" jsonschema:"choose OK once typed; default true"`
}

// typeTextRequest is what the driver receives: confirm is always spelled out.
type typeTextRequest struct {
	Text    string `json:"text"`
	Confirm bool   `json:"confirm"`
}

func (t *tools) typeText(ctx context.Context, _ *mcp.CallToolRequest, in TypeTextIn) (*mcp.CallToolResult, any, error) {
	if in.Text == "" || len(in.Text) > MaxTypeTextBytes {
		return nil, nil, fmt.Errorf("text must be 1 to %d bytes, got %d", MaxTypeTextBytes, len(in.Text))
	}
	req := typeTextRequest{Text: in.Text, Confirm: in.Confirm == nil || *in.Confirm}
	raw, err := t.forward(ctx, "type_text", "type_text", req, CallTimeout+2*time.Minute)
	return nil, raw, err
}

// SetClockIn is the set_clock tool's input. Hours and minutes are pointers so that 0 is a time and a missing one is
// refused.
type SetClockIn struct {
	Hours   *int  `json:"hours" jsonschema:"the hour, 0 to 23"`
	Minutes *int  `json:"minutes" jsonschema:"the minute, 0 to 59"`
	Confirm *bool `json:"confirm,omitempty" jsonschema:"answer the game's question YES once set; default true"`
}

// setClockRequest is what the driver receives: every field spelled out.
type setClockRequest struct {
	Hours   int  `json:"hours"`
	Minutes int  `json:"minutes"`
	Confirm bool `json:"confirm"`
}

func (t *tools) setClock(ctx context.Context, _ *mcp.CallToolRequest, in SetClockIn) (*mcp.CallToolResult, any, error) {
	if in.Hours == nil || *in.Hours < 0 || *in.Hours > 23 {
		return nil, nil, fmt.Errorf("hours must be 0 to 23")
	}
	if in.Minutes == nil || *in.Minutes < 0 || *in.Minutes > 59 {
		return nil, nil, fmt.Errorf("minutes must be 0 to 59")
	}
	req := setClockRequest{Hours: *in.Hours, Minutes: *in.Minutes, Confirm: in.Confirm == nil || *in.Confirm}
	raw, err := t.forward(ctx, "set_clock", "set_clock", req, CallTimeout+time.Minute)
	return nil, raw, err
}

// MaxScreenshotBytes bounds a picture the core will read back and return.
const MaxScreenshotBytes = 4 << 20

// ScreenshotIn is the screenshot tool's input.
type ScreenshotIn struct {
	Name string `json:"name" jsonschema:"a short label for the file: letters, digits, _ or -"`
}

func (t *tools) screenshot(ctx context.Context, _ *mcp.CallToolRequest, in ScreenshotIn) (*mcp.CallToolResult, any, error) {
	raw, err := t.forward(ctx, "screenshot", "screenshot", in, CallTimeout)
	if err != nil {
		return nil, nil, err
	}
	var shot struct {
		Path string `json:"path"`
	}
	if json.Unmarshal(raw, &shot) != nil || shot.Path == "" {
		return nil, nil, fmt.Errorf("the driver's screenshot answer names no file: %s", raw)
	}
	if !strings.EqualFold(filepath.Ext(shot.Path), ".png") {
		return nil, nil, fmt.Errorf("the driver named %q, which is not a .png", shot.Path)
	}
	info, err := os.Stat(shot.Path)
	if err != nil {
		return nil, nil, fmt.Errorf("the driver's screenshot: %w", err)
	}
	if info.Size() > MaxScreenshotBytes {
		return nil, nil, fmt.Errorf("the screenshot is %d bytes, over the %d-byte cap", info.Size(), MaxScreenshotBytes)
	}
	png, err := os.ReadFile(shot.Path)
	if err != nil {
		return nil, nil, fmt.Errorf("the driver's screenshot: %w", err)
	}
	return &mcp.CallToolResult{Content: []mcp.Content{
		&mcp.TextContent{Text: string(raw)},
		&mcp.ImageContent{Data: png, MIMEType: "image/png"},
	}}, nil, nil
}

// EventsIn is the events tool's input.
type EventsIn struct {
	Since uint64 `json:"since" jsonschema:"return events with a sequence number above this; 0 for all buffered"`
}

// EventOut is one event as the tool returns it. The payload is decoded rather than passed as raw
// bytes: the output schema is inferred from these types, and a json.RawMessage infers as an array
// of bytes, which every real event -- a JSON object -- then fails validation against.
type EventOut struct {
	Seq     uint64    `json:"seq"`
	At      time.Time `json:"at"`
	Payload any       `json:"payload"`
}

// EventsOut is the events tool's answer.
type EventsOut struct {
	Events []EventOut `json:"events"`
	Newest uint64     `json:"newest"`
}

func (t *tools) events(ctx context.Context, _ *mcp.CallToolRequest, in EventsIn) (*mcp.CallToolResult, EventsOut, error) {
	evs, newest := t.hub.EventsSince(in.Since)
	out := EventsOut{Events: []EventOut{}, Newest: newest}
	for _, e := range evs {
		var payload any
		if err := json.Unmarshal(e.Payload, &payload); err != nil {
			payload = string(e.Payload)
		}
		out.Events = append(out.Events, EventOut{Seq: e.Seq, At: e.At, Payload: payload})
	}
	return nil, out, nil
}

var labelPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
var kindPattern = regexp.MustCompile(`^[a-z_]{1,32}$`)

// SnapshotIn is the snapshot tool's input.
type SnapshotIn struct {
	Label string `json:"label" jsonschema:"a name for the state: letters, digits, _ or -, up to 64"`
}

// RestoreIn is the restore tool's input.
type RestoreIn struct {
	Label string `json:"label" jsonschema:"the name a snapshot was saved under"`
}

// statePath is where a label's snapshot lives for the connected game, as an absolute path the
// driver can use whatever its working directory is.
func (t *tools) statePath(label string) (string, driver.Hello, error) {
	hello, ok := t.hub.Current()
	if !ok {
		return "", hello, driver.ErrNoDriver
	}
	if !labelPattern.MatchString(label) {
		return "", hello, fmt.Errorf("a label is letters, digits, _ or -, up to 64: got %q", label)
	}
	if !labelPattern.MatchString(hello.Game) {
		return "", hello, fmt.Errorf("the driver's game name %q cannot be a folder name", hello.Game)
	}
	dir, err := filepath.Abs(filepath.Join(t.statesDir, hello.Game))
	if err != nil {
		return "", hello, err
	}
	return filepath.Join(dir, label+".State"), hello, nil
}

func (t *tools) snapshot(ctx context.Context, _ *mcp.CallToolRequest, in SnapshotIn) (*mcp.CallToolResult, any, error) {
	path, _, err := t.statePath(in.Label)
	if err != nil {
		return nil, nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, nil, err
	}
	before, _ := os.Stat(path)
	raw, err := t.forward(ctx, "snapshot", "snapshot", map[string]string{"path": filepath.ToSlash(path)}, CallTimeout)
	if err != nil {
		return nil, nil, err
	}
	// Never trust the answer alone: the file must exist, and be new if one was there before.
	after, statErr := os.Stat(path)
	if statErr != nil {
		return nil, nil, fmt.Errorf("the driver answered but no snapshot file exists at %s: %w", path, statErr)
	}
	if before != nil && !after.ModTime().After(before.ModTime()) {
		return nil, nil, fmt.Errorf("the driver answered but %s was not rewritten", path)
	}
	return nil, map[string]any{"label": in.Label, "path": path, "bytes": after.Size(), "driver": raw}, nil
}

func (t *tools) restore(ctx context.Context, _ *mcp.CallToolRequest, in RestoreIn) (*mcp.CallToolResult, any, error) {
	path, _, err := t.statePath(in.Label)
	if err != nil {
		return nil, nil, err
	}
	if _, err := os.Stat(path); err != nil {
		return nil, nil, fmt.Errorf("no snapshot named %q: %w", in.Label, err)
	}
	raw, err := t.forward(ctx, "restore", "restore", map[string]string{"path": filepath.ToSlash(path)}, CallTimeout)
	return nil, raw, err
}

// CheatIn is the cheat tool's input.
type CheatIn struct {
	Kind string         `json:"kind" jsonschema:"a cheat the driver announced as cheat:<kind>, e.g. warp"`
	Args map[string]any `json:"args,omitempty" jsonschema:"that kind's arguments, as the driver documents them"`
}

// CheatTimeout allows for a cheat that ends on the game's state, such as a map load.
const CheatTimeout = CallTimeout + 30*time.Second

func (t *tools) cheat(ctx context.Context, _ *mcp.CallToolRequest, in CheatIn) (*mcp.CallToolResult, any, error) {
	if !kindPattern.MatchString(in.Kind) {
		return nil, nil, fmt.Errorf("a cheat kind is lowercase letters and _: got %q", in.Kind)
	}
	if in.Args == nil {
		in.Args = map[string]any{}
	}
	raw, err := t.forward(ctx, "cheat:"+in.Kind, "cheat", in, CheatTimeout)
	if err == nil {
		t.notePersisting(raw)
	}
	return nil, raw, err
}

// notePersisting keeps a cheat answer's list of cheats still in effect, when it carries one.
func (t *tools) notePersisting(raw json.RawMessage) {
	var answer struct {
		Persisting *driver.Kinds `json:"persisting"`
	}
	if json.Unmarshal(raw, &answer) != nil || answer.Persisting == nil {
		return
	}
	_, gen, ok := t.hub.CurrentConnection()
	if !ok {
		return
	}
	t.persistMu.Lock()
	defer t.persistMu.Unlock()
	t.persistGen, t.persistKinds = gen, append([]string(nil), (*answer.Persisting)...)
}

// stillOn names the cheats in effect on the connected driver: what its last cheat answer said, or its
// hello when no cheat has answered on this connection. Nothing without a driver.
func (t *tools) stillOn() []string {
	hello, gen, ok := t.hub.CurrentConnection()
	if !ok {
		return nil
	}
	t.persistMu.Lock()
	defer t.persistMu.Unlock()
	kinds := hello.Persisting
	if gen == t.persistGen {
		kinds = t.persistKinds
	}
	var out []string
	for _, k := range kinds {
		out = append(out, "cheat:"+k+" (still on)")
	}
	return out
}

// MaxExecBytes bounds exec's code: it travels in one line of the link, escaped.
const MaxExecBytes = 16 * 1024

// ExecIn is the exec tool's input.
type ExecIn struct {
	Code string `json:"code" jsonschema:"the code to run, in the host's own language (Lua on BizHawk); return values come back"`
}

// execRequest is what the driver receives.
type execRequest struct {
	Code  string `json:"code"`
	Token string `json:"token"`
}

func (t *tools) exec(ctx context.Context, _ *mcp.CallToolRequest, in ExecIn) (*mcp.CallToolResult, any, error) {
	if in.Code == "" || len(in.Code) > MaxExecBytes {
		return nil, nil, fmt.Errorf("code must be 1 to %d bytes, got %d", MaxExecBytes, len(in.Code))
	}
	if t.execToken == "" {
		return nil, nil, fmt.Errorf("this core was started without an exec token, so exec is off")
	}
	raw, err := t.forward(ctx, "exec", "exec", execRequest{Code: in.Code, Token: t.execToken}, CallTimeout)
	return nil, raw, err
}

// WriteExecToken makes this session's exec token and writes it to path, readable by this user: the
// driver runs code only for a request carrying what that file holds, so exec takes a process that can
// read this repo's runs folder, not merely one that reaches the loopback port first.
func WriteExecToken(path string) (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	token := hex.EncodeToString(b)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(token), 0o600); err != nil {
		return "", err
	}
	return token, nil
}

// SegmentIn is the segment tool's input.
type SegmentIn struct {
	Label string `json:"label" jsonschema:"what the next stretch of the run sets out to do"`
}

// SegmentOut is the segment tool's answer.
type SegmentOut struct {
	Closed  runlog.Segment `json:"closed"`
	Current runlog.Segment `json:"current"`
	LogFile string         `json:"log_file"`
}

func (t *tools) segment(ctx context.Context, _ *mcp.CallToolRequest, in SegmentIn) (*mcp.CallToolResult, SegmentOut, error) {
	if t.log == nil {
		return nil, SegmentOut{}, fmt.Errorf("this core was started without a run log")
	}
	if in.Label == "" || len(in.Label) > 200 {
		return nil, SegmentOut{}, fmt.Errorf("a segment label is 1 to 200 characters")
	}
	// A cheat still in effect (a noclip left on) reaches the new segment from its first frame.
	closed := t.log.Begin(in.Label, t.stillOn()...)
	return nil, SegmentOut{Closed: closed, Current: t.log.Current(), LogFile: t.log.Path()}, nil
}

// forward checks the capability, then asks the driver.
func (t *tools) forward(ctx context.Context, capability, verb string, payload any, timeout time.Duration) (json.RawMessage, error) {
	hello, ok := t.hub.Current()
	if !ok {
		return nil, driver.ErrNoDriver
	}
	if !hello.Has(capability) {
		return nil, fmt.Errorf("the connected driver (%s, %s) does not support %q; it supports %v",
			hello.Host, hello.Game, capability, hello.Capabilities)
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return t.hub.Call(ctx, verb, payload)
}
