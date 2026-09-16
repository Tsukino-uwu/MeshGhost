// Command scenario runs scenario files against a game driver with no model: the autoplay core's own
// server runs in this process, a driver connects to it as it would to a session's core, and every step
// is a tool call through that server, so the run log labels each run's setup and steps walked or
// reached exactly as it does a session's. Dev-only, never shipped (agent_docs/phases/phase13.md).
//
//	go run ./cmd/scenario games/emerald/scenarios/trainer_sight_range.json
//
// Run from autoplay/. Arguments are scenario files or folders of them (*.json). Exit 0 when every run
// passed, 1 when one failed, 2 when nothing could be run (a file that does not load, no driver, another
// game connected).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/driver"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/runlog"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/scenario"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/server"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const version = "0.1.0"

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	code := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	os.Exit(code)
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("scenario", flag.ContinueOnError)
	fs.SetOutput(stderr)
	listen := fs.String("listen", "127.0.0.1:7870", "loopback address the game driver connects to")
	wait := fs.Duration("wait", 30*time.Second, "how long to wait for a driver to connect")
	repeat := fs.Int("repeat", 0, "run each scenario this many times instead of its file's repeat")
	all := fs.Bool("all", false, "run every repeat even after one fails")
	logPath := fs.String("log", "runs/scenario.log", "the core's log file")
	runsDir := fs.String("runs", "runs", "folder for the run log (gitignored)")
	statesDir := fs.String("states", "states", "the snapshots folder the server is given (a scenario never uses it)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() == 0 {
		fmt.Fprintln(stderr, "scenario: name one or more scenario files or folders")
		return 2
	}
	if *repeat < 0 || *repeat > scenario.MaxRepeat {
		fmt.Fprintf(stderr, "scenario: -repeat must be 0 to %d\n", scenario.MaxRepeat)
		return 2
	}
	scenarios, err := loadAll(fs.Args())
	if err != nil {
		fmt.Fprintf(stderr, "scenario: %v\n", err)
		return 2
	}

	logger, closeLog, err := openLog(*logPath)
	if err != nil {
		fmt.Fprintf(stderr, "scenario: %v\n", err)
		return 2
	}
	defer closeLog()
	hub, err := driver.Listen(*listen, logger)
	if err != nil {
		fmt.Fprintf(stderr, "scenario: driver listener: %v\n", err)
		return 2
	}
	runs, err := runlog.Open(*runsDir)
	if err != nil {
		hub.Close()
		fmt.Fprintf(stderr, "scenario: run log: %v\n", err)
		return 2
	}
	defer runs.Close()
	fmt.Fprintf(stdout, "run log %s; waiting for a driver on %s\n", runs.Path(), hub.Addr())
	return serve(ctx, hub, runs, *statesDir, scenarios, scenario.Options{Repeat: *repeat, All: *all, Out: stdout}, *wait, stdout, stderr)
}

// serve runs the scenarios through a server over hub, in this process. It owns the hub from here on.
func serve(ctx context.Context, hub *driver.Hub, runs *runlog.Log, statesDir string, scenarios []*scenario.Scenario,
	opts scenario.Options, wait time.Duration, stdout, stderr io.Writer) int {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go hub.Serve(ctx)
	defer hub.Close()

	serverT, clientT := mcp.NewInMemoryTransports()
	if _, err := server.New(hub, version, server.Options{Log: runs, StatesDir: statesDir}).Connect(ctx, serverT, nil); err != nil {
		fmt.Fprintf(stderr, "scenario: server: %v\n", err)
		return 2
	}
	session, err := mcp.NewClient(&mcp.Implementation{Name: "scenario", Version: version}, nil).Connect(ctx, clientT, nil)
	if err != nil {
		fmt.Fprintf(stderr, "scenario: client: %v\n", err)
		return 2
	}
	defer session.Close()
	caller := scenario.SessionCaller{Session: session}

	// Every tool a step names must exist before anything runs: a typo found on run 3 wastes runs 1 and 2.
	known := map[string]bool{}
	for tool, err := range session.Tools(ctx, nil) {
		if err != nil {
			fmt.Fprintf(stderr, "scenario: list tools: %v\n", err)
			return 2
		}
		known[tool.Name] = true
	}
	for _, s := range scenarios {
		for _, st := range append(append([]scenario.Step(nil), s.Setup...), s.Steps...) {
			if !known[st.Tool] {
				fmt.Fprintf(stderr, "scenario: %s calls %q, which the server does not have\n", s.Name, st.Tool)
				return 2
			}
		}
	}

	if !waitForDriver(ctx, hub, wait) {
		fmt.Fprintf(stderr, "scenario: no driver connected within %s\n", wait)
		return 2
	}

	code := 0
	var summary []string
	for _, s := range scenarios {
		rep, err := scenario.Run(ctx, caller, s, opts)
		if err != nil {
			// A refusal (another game connected) or the link failing: either way this scenario did not run to a
			// verdict, and neither will the ones after it.
			what := "stopped"
			if errors.Is(err, scenario.ErrRefused) {
				what = "not run"
			}
			fmt.Fprintf(stderr, "scenario: %s %s: %v\n", s.Name, what, err)
			return 2
		}
		verdict := "PASS"
		if !rep.OK() {
			verdict, code = "FAIL", 1
		}
		summary = append(summary, fmt.Sprintf("%s %s %d/%d", verdict, s.Name, rep.Passed, rep.Want))
	}
	if len(scenarios) > 1 {
		fmt.Fprintln(stdout, strings.Join(summary, "\n"))
	}
	return code
}

func waitForDriver(ctx context.Context, hub *driver.Hub, wait time.Duration) bool {
	deadline := time.Now().Add(wait)
	for {
		if _, ok := hub.Current(); ok {
			return true
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			return false
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// loadAll loads every file named, and every *.json in every folder named, in name order.
func loadAll(args []string) ([]*scenario.Scenario, error) {
	var files []string
	for _, a := range args {
		info, err := os.Stat(a)
		if err != nil {
			return nil, err
		}
		if !info.IsDir() {
			files = append(files, a)
			continue
		}
		found, err := filepath.Glob(filepath.Join(a, "*.json"))
		if err != nil {
			return nil, err
		}
		if len(found) == 0 {
			return nil, fmt.Errorf("%s holds no *.json", a)
		}
		sort.Strings(found)
		files = append(files, found...)
	}
	var out []*scenario.Scenario
	for _, f := range files {
		s, err := scenario.Load(f)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, nil
}

func openLog(path string) (*log.Logger, func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, nil, fmt.Errorf("log folder: %w", err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, nil, fmt.Errorf("open log: %w", err)
	}
	return log.New(f, "scenario: ", log.LstdFlags|log.Lmicroseconds), func() { f.Close() }, nil
}
