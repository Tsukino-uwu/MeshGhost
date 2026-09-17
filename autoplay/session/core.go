package session

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Core is a short-lived client of an autoplay core the launcher starts itself, before and after the model's session,
// on the same port and run log: the snapshot restored and the goal checked with no model.
type Core struct {
	session *mcp.ClientSession
}

// StartCore starts the core binary with args and connects to it over stdio.
func StartCore(ctx context.Context, binary string, args []string) (*Core, error) {
	cmd := exec.Command(binary, args...)
	s, err := mcp.NewClient(&mcp.Implementation{Name: "autoplay-session", Version: "1"}, nil).
		Connect(ctx, &mcp.CommandTransport{Command: cmd}, nil)
	if err != nil {
		return nil, fmt.Errorf("start the core: %w", err)
	}
	return &Core{session: s}, nil
}

// Close stops the core.
func (c *Core) Close() error { return c.session.Close() }

// Call makes one tool call and decodes its answer into out (when not nil). A tool's refusal is an error.
func (c *Core) Call(ctx context.Context, tool string, args map[string]any, out any) error {
	if args == nil {
		args = map[string]any{}
	}
	res, err := c.session.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		return fmt.Errorf("%s: %w", tool, err)
	}
	var b strings.Builder
	for _, content := range res.Content {
		if tc, ok := content.(*mcp.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	if res.IsError {
		return fmt.Errorf("%s answered: %s", tool, b.String())
	}
	if out != nil {
		if err := json.Unmarshal([]byte(b.String()), out); err != nil {
			return fmt.Errorf("%s's answer does not parse: %w", tool, err)
		}
	}
	return nil
}

// Hello is the part of status the launcher reads.
type Hello struct {
	Connected bool `json:"connected"`
	Driver    *struct {
		Game    string `json:"game"`
		Variant string `json:"variant"`
	} `json:"driver"`
}

// WaitForDriver polls status until a driver is connected, and returns its hello.
func (c *Core) WaitForDriver(ctx context.Context, wait time.Duration) (Hello, error) {
	deadline := time.Now().Add(wait)
	for {
		var h Hello
		if err := c.Call(ctx, "status", nil, &h); err != nil {
			return h, err
		}
		if h.Connected && h.Driver != nil {
			return h, nil
		}
		if time.Now().After(deadline) {
			return h, fmt.Errorf("no driver connected within %s", wait)
		}
		select {
		case <-ctx.Done():
			return h, ctx.Err()
		case <-time.After(250 * time.Millisecond):
		}
	}
}
