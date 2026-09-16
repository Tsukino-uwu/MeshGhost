// Command mcpcall is a dev tool for testing the harness without an agent: it starts the autoplay core
// as an MCP server over stdio -- the same way Claude Code does -- calls a list of tools in order,
// and prints each answer. A game tool waits up to -wait for a driver to connect first.
//
//	go run ./cmd/mcpcall -calls '[{"name":"status"},{"name":"press","arguments":{"buttons":["Down"],"frames":16}}]'
//
// Run from autoplay/. The core it starts logs to runs/core.log.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type call struct {
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments,omitempty"`
}

func main() {
	listen := flag.String("listen", "127.0.0.1:7870", "the core's driver port")
	callsJSON := flag.String("calls", `[{"name":"status"}]`, "a JSON array of {name, arguments}")
	wait := flag.Duration("wait", 30*time.Second, "how long a game tool waits for a driver to connect")
	coreCmd := flag.String("core", "go run ./cmd/autoplay", "the command that starts the core, run from autoplay/")
	flag.Parse()

	var calls []call
	if err := json.Unmarshal([]byte(*callsJSON), &calls); err != nil {
		fmt.Fprintf(os.Stderr, "mcpcall: -calls: %v\n", err)
		os.Exit(2)
	}

	ctx := context.Background()
	argv := append(strings.Fields(*coreCmd), "-listen", *listen, "-log", "runs/core.log")
	core := exec.Command(argv[0], argv[1:]...)
	core.Stderr = os.Stderr

	client := mcp.NewClient(&mcp.Implementation{Name: "mcpcall", Version: "dev"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: core}, nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mcpcall: start the core: %v\n", err)
		os.Exit(1)
	}
	defer session.Close()

	failed := false
	for _, c := range calls {
		if c.Name != "status" && c.Name != "events" && !waitForDriver(ctx, session, *wait) {
			fmt.Printf("== %s: no driver connected within %s\n", c.Name, *wait)
			failed = true
			break
		}
		args := c.Arguments
		if args == nil {
			args = map[string]any{}
		}
		res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: c.Name, Arguments: args})
		if err != nil {
			fmt.Printf("== %s: protocol error: %v\n", c.Name, err)
			failed = true
			break
		}
		fmt.Printf("== %s (error=%v)\n%s\n", c.Name, res.IsError, textOf(res))
		if res.IsError {
			failed = true
		}
	}
	if failed {
		os.Exit(1)
	}
}

func textOf(res *mcp.CallToolResult) string {
	var b strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	return b.String()
}

// waitForDriver polls status until a driver is connected or the wait runs out.
func waitForDriver(ctx context.Context, session *mcp.ClientSession, wait time.Duration) bool {
	deadline := time.Now().Add(wait)
	for {
		res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "status", Arguments: map[string]any{}})
		if err == nil && strings.Contains(textOf(res), `"connected":true`) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(250 * time.Millisecond)
	}
}
