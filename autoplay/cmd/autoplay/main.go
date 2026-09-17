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
	"net"
	"os"
	"os/signal"
	"path/filepath"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/driver"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/runlog"
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
	runsDir := flag.String("runs", "runs", "folder for this session's run log (gitignored)")
	statesDir := flag.String("states", "states", "folder for named snapshots (gitignored)")
	gamesDir := flag.String("games", "games", "folder of each game's knowledge store: goals.json, skills/ (tracked)")
	resume := flag.String("resume", "", "carry on this run log instead of starting one, its open segment included")
	execToken := flag.String("exec-token", "", "file for this session's exec token; default <runs>/exec_token_<port>.txt, where the BizHawk driver looks")
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

	var runs *runlog.Log
	if *resume != "" {
		runs, err = runlog.Resume(*resume)
	} else {
		runs, err = runlog.Open(*runsDir)
	}
	if err != nil {
		logger.Printf("run log: %v", err)
		os.Exit(1)
	}
	logger.Printf("run log %s", runs.Path())

	// Written only once the port is ours: a core that failed to bind must not replace the running one's token.
	tokenPath := *execToken
	if tokenPath == "" {
		_, port, _ := net.SplitHostPort(hub.Addr().String())
		tokenPath = filepath.Join(*runsDir, "exec_token_"+port+".txt")
	}
	token, err := server.WriteExecToken(tokenPath)
	if err != nil {
		logger.Printf("exec token: %v; exec is off", err)
		token = ""
	} else {
		defer os.Remove(tokenPath)
		logger.Printf("exec token written to %s", tokenPath)
	}

	srv := server.New(hub, version, server.Options{Log: runs, StatesDir: *statesDir, GamesDir: *gamesDir, ExecToken: token})
	if err := srv.Run(ctx, &mcp.StdioTransport{}); err != nil && ctx.Err() == nil {
		logger.Printf("mcp: %v", err)
	}
	hub.Close()
	runs.Close()
	logger.Printf("stopped")
}
