// Command autoplay is the dev-only harness core: an MCP server on stdin/stdout that Claude Code
// starts, plus a loopback listener one game driver connects to. It is never built by a MeshGhost
// release and never shipped (agent_docs/phases/phase13.md).
//
// stdout belongs to MCP. Every log line goes to stderr, or to -log when given.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/driver"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/server"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// DefaultListen is where a driver connects when nothing else is said. One instance, one core,
// one port: a second instance's handoff names its own with -listen.
const DefaultListen = "127.0.0.1:7870"

const version = "0.1.0"

func main() {
	listen := flag.String("listen", DefaultListen, "loopback address the game driver connects to")
	logPath := flag.String("log", "", "append log lines to this file instead of stderr")
	flag.Parse()

	var out io.Writer = os.Stderr
	if *logPath != "" {
		if err := os.MkdirAll(filepath.Dir(*logPath), 0o755); err != nil {
			fmt.Fprintf(os.Stderr, "autoplay: log folder: %v\n", err)
			os.Exit(1)
		}
		f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			fmt.Fprintf(os.Stderr, "autoplay: open log: %v\n", err)
			os.Exit(1)
		}
		defer f.Close()
		out = f
	}
	logger := log.New(out, "autoplay: ", log.LstdFlags|log.Lmicroseconds)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	hub, err := driver.Listen(*listen, logger)
	if err != nil {
		logger.Printf("driver listener: %v", err)
		os.Exit(1)
	}
	logger.Printf("version %s; waiting for a driver on %s", version, hub.Addr())
	go func() {
		if err := hub.Serve(ctx); err != nil {
			logger.Printf("driver listener stopped: %v", err)
		}
	}()

	if err := server.New(hub, version).Run(ctx, &mcp.StdioTransport{}); err != nil && ctx.Err() == nil {
		logger.Printf("mcp: %v", err)
	}
	hub.Close()
	logger.Printf("stopped")
}
