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
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/driver"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// CallTimeout is the base time a driver gets to answer; input that runs for frames gets more.
const CallTimeout = 10 * time.Second

// MaxPressFrames bounds one press: a long hold is a leg, and legs end on the game's state.
const MaxPressFrames = 600

// New builds the MCP server over a hub.
func New(hub *driver.Hub, version string) *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: "autoplay", Version: version}, nil)
	t := &tools{hub: hub}

	mcp.AddTool(s, &mcp.Tool{
		Name: "status",
		Description: "Whether a game driver is connected, and what it says about itself: host, game, " +
			"variant, build, the capabilities it supports and the savestate slots it protects. " +
			"Call this first in a session.",
	}, t.status)

	mcp.AddTool(s, &mcp.Tool{
		Name: "observe",
		Description: "A snapshot of the game as the driver reads it from memory (position, map, " +
			"whatever the driver supports). Every name in it comes from the driver.",
	}, t.observe)

	mcp.AddTool(s, &mcp.Tool{
		Name: "press",
		Description: "Hold buttons for a number of frames, then release. The raw escape hatch: " +
			"prefer a tool that ends on the game's own state when the driver has one. " +
			"Returns what the driver saw change.",
	}, t.press)

	mcp.AddTool(s, &mcp.Tool{
		Name: "wait",
		Description: "Let frames pass with no input at all, then return what changed. Use this to " +
			"wait -- never hold a button to wait, since every button does something somewhere.",
	}, t.wait)

	mcp.AddTool(s, &mcp.Tool{
		Name: "screenshot",
		Description: "A picture of the game frame, saved under dev-scripts/shots/<game>/ and returned " +
			"as an image. The navigation sense: what is around, what a thing is, which entry is " +
			"highlighted. Never proof of anything visual.",
	}, t.screenshot)

	mcp.AddTool(s, &mcp.Tool{
		Name:        "events",
		Description: "Events the driver reported since a sequence number (0 for everything buffered).",
	}, t.events)

	return s
}

type tools struct {
	hub *driver.Hub
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
