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

// EventsIn is the events tool's input.
type EventsIn struct {
	Since uint64 `json:"since" jsonschema:"return events with a sequence number above this; 0 for all buffered"`
}

// EventsOut is the events tool's answer.
type EventsOut struct {
	Events []driver.Event `json:"events"`
	Newest uint64         `json:"newest"`
}

func (t *tools) events(ctx context.Context, _ *mcp.CallToolRequest, in EventsIn) (*mcp.CallToolResult, EventsOut, error) {
	evs, newest := t.hub.EventsSince(in.Since)
	if evs == nil {
		evs = []driver.Event{}
	}
	return nil, EventsOut{Events: evs, Newest: newest}, nil
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
