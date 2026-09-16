// Package server is the MCP face of the core: the tools an agent calls, each one either answered
// by the core itself or forwarded to the connected driver.
//
// A tool that needs the game checks the driver's announced capabilities first, so a driver that
// cannot do a thing produces a plain refusal rather than a call it will fail. Everything a driver
// returns is passed through unread: the core stays game-blind.
package server

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/driver"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/runlog"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// CallTimeout is the base time a driver gets to answer; input that runs for frames gets more.
const CallTimeout = 10 * time.Second

// MaxPressFrames bounds one press: a long hold is a leg, and legs end on the game's state.
const MaxPressFrames = 600

// Options are what the server needs besides the hub. A zero Options is valid: no run log, and
// snapshots under "states".
type Options struct {
	Log       *runlog.Log
	StatesDir string
}

// New builds the MCP server over a hub.
func New(hub *driver.Hub, version string, opts Options) *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "autoplay", Version: version}, nil)
	if opts.StatesDir == "" {
		opts.StatesDir = "states"
	}
	t := &tools{hub: hub, log: opts.Log, statesDir: opts.StatesDir}

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
			"dialogue_open, menu_open, left_overworld. Returns the tiles moved and what changed. " +
			"run: true runs where the save can; walk for precision, run for speed.",
	}, logged(t, "walk", nil, t.walk))

	mcp.AddTool(s, &mcp.Tool{
		Name: "goto",
		Description: "Move the player to a tile on this map by a planned route: straight legs, turning at " +
			"speed, replanning around what refuses a step. Rides whatever the player is on (on foot, " +
			"run: true to run). Stops early and says why, as walk does, or unreachable (with the reason). " +
			"Returns where it ended, the tiles moved, turns and replans.",
	}, logged(t, "goto", nil, t.gotoTile))

	mcp.AddTool(s, &mcp.Tool{
		Name: "battle",
		Description: "Play the battle on screen to its end in one call, a trainer's words before and after " +
			"included. policy strongest (default) fights with the usable move of most power times accuracy; " +
			"run runs. Returns a log of every message and choice, and ends ended, needs_choice (a menu it " +
			"will not answer) or stuck (with what it was waiting on) -- within seconds of nothing changing.",
	}, logged(t, "battle", nil, t.battle))

	mcp.AddTool(s, &mcp.Tool{
		Name: "advance_text",
		Description: "Press through the message on screen, box by box. Stops when it closes, when a menu " +
			"opens (answer it with select), when a battle begins (use battle), or stuck. Returns a log of " +
			"every box.",
	}, logged(t, "advance_text", nil, t.advanceText))

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

// GotoIn is the goto tool's input.
type GotoIn struct {
	X          int  `json:"x" jsonschema:"the target tile's x on this map"`
	Y          int  `json:"y" jsonschema:"the target tile's y on this map"`
	Run        bool `json:"run,omitempty" jsonschema:"run where on foot"`
	CrossGrass bool `json:"cross_grass,omitempty" jsonschema:"route through tall grass freely, as with a Repel running; by default the route avoids it where it can"`
}

func (t *tools) gotoTile(ctx context.Context, _ *mcp.CallToolRequest, in GotoIn) (*mcp.CallToolResult, any, error) {
	if in.X < 0 || in.Y < 0 || in.X > MaxGotoCoordinate || in.Y > MaxGotoCoordinate {
		return nil, nil, fmt.Errorf("x and y must be 0 to %d, got %d,%d", MaxGotoCoordinate, in.X, in.Y)
	}
	raw, err := t.forward(ctx, "goto", "goto", in, GotoTimeout)
	return nil, raw, err
}

// BattleTimeout allows a long battle: the driver ends a stuck one within seconds on its own.
const BattleTimeout = CallTimeout + 10*time.Minute

// BattleIn is the battle tool's input.
type BattleIn struct {
	Policy string `json:"policy,omitempty" jsonschema:"strongest (default) or run"`
}

func (t *tools) battle(ctx context.Context, _ *mcp.CallToolRequest, in BattleIn) (*mcp.CallToolResult, any, error) {
	switch in.Policy {
	case "", "strongest", "run":
	default:
		return nil, nil, fmt.Errorf(`policy must be "strongest" or "run", got %q`, in.Policy)
	}
	raw, err := t.forward(ctx, "battle", "battle", in, BattleTimeout)
	return nil, raw, err
}

func (t *tools) advanceText(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, any, error) {
	raw, err := t.forward(ctx, "advance_text", "advance_text", struct{}{}, CallTimeout+3*time.Minute)
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
	return nil, raw, err
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
	closed := t.log.Begin(in.Label)
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
