// Command session runs one unattended Claude Code session toward a goal, on the user's Claude subscription only, and
// reports it (the plan's session loop, Phase 3). Dev-only, never shipped (agent_docs/phases/phase13.md).
//
//	go run ./cmd/session -core <built autoplay.exe> -claude <claude executable> -goal story_heat_badge -snapshot story_dynamo_badge
//
// Run from autoplay/, with the game's driver waiting for a core on -listen and nothing else on that port. In order:
//  1. refuses to start while an API key or a cloud provider is set in the environment (session.CheckEnv);
//  2. with no model, starts the core, restores the snapshot, opens the session's segment and checks the goal;
//  3. plays: a headless `claude -p` given play.md, the core as its only MCP server, the game's tools and read-only file
//     tools, stopped by the launcher once it has made -budget model calls;
//  4. distills: the same session resumed with distill.md, editing only the game's knowledge store, -distill-budget calls;
//  5. with no model again, closes the segment, checks the goal and reads where the game was left;
//  6. writes report.json and report.md, with the stream of each run, into runs/sessions/<time>/ (gitignored).
//
// It never commits: the knowledge store's diff is read by a person against "measured or observed only" first.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/session"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	code := run(ctx, os.Args[1:], os.Stdout, os.Stderr)
	stop()
	os.Exit(code)
}

type options struct {
	game, goal, snapshot, listen, core, claude, model string
	budget, distillBudget                             int
	out, runs, states, games, repo                    string
	wait                                              time.Duration
	dryRun                                            bool
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("session", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var o options
	fs.StringVar(&o.game, "game", "emerald", "the game the driver must be (its knowledge store's folder)")
	fs.StringVar(&o.goal, "goal", "", "the goal's id in the game's goals.json")
	fs.StringVar(&o.snapshot, "snapshot", "", "the snapshot the session starts from")
	fs.StringVar(&o.listen, "listen", "127.0.0.1:7870", "the driver's port")
	fs.StringVar(&o.core, "core", "", "a built autoplay core (go build -o <dir>/autoplay.exe ./cmd/autoplay)")
	fs.StringVar(&o.claude, "claude", "claude", "the Claude Code executable")
	fs.StringVar(&o.model, "model", "", "the model the session runs; empty for the account's default. Give the same one to every attempt compared")
	fs.IntVar(&o.budget, "budget", 400, "model calls the play may make before it is stopped")
	fs.IntVar(&o.distillBudget, "distill-budget", 40, "model calls the distillation may make; 0 skips it")
	fs.StringVar(&o.out, "out", "runs/sessions", "where each session's folder is made (gitignored)")
	fs.StringVar(&o.runs, "runs", "runs", "the run logs' folder")
	fs.StringVar(&o.states, "states", "states", "the snapshots' folder")
	fs.StringVar(&o.games, "games", "games", "the knowledge store")
	fs.StringVar(&o.repo, "repo", "..", "the repository's root: the session's working folder")
	fs.DurationVar(&o.wait, "wait", 60*time.Second, "how long to wait for the driver")
	fs.BoolVar(&o.dryRun, "dry-run", false, "print what would run, and run nothing")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if o.goal == "" || o.snapshot == "" || o.core == "" {
		fmt.Fprintln(stderr, "session: -goal, -snapshot and -core are required")
		return 2
	}
	if o.budget < 1 || o.distillBudget < 0 {
		fmt.Fprintln(stderr, "session: -budget must be at least 1 and -distill-budget at least 0")
		return 2
	}
	if err := session.CheckEnv(os.Environ()); err != nil {
		fmt.Fprintf(stderr, "session: %v\n", err)
		return 2
	}
	for _, p := range []*string{&o.core, &o.out, &o.runs, &o.states, &o.games, &o.repo} {
		abs, err := filepath.Abs(*p)
		if err != nil {
			fmt.Fprintf(stderr, "session: %v\n", err)
			return 2
		}
		*p = abs
	}
	if err := runSession(ctx, o, stdout, stderr); err != nil {
		fmt.Fprintf(stderr, "session: %v\n", err)
		return 1
	}
	return 0
}

// goalAnswer is the part of the goal tool's answer the launcher reads.
type goalAnswer struct {
	Goal *struct {
		Description string   `json:"description"`
		Met         bool     `json:"met"`
		Failed      []string `json:"failed"`
	} `json:"goal"`
}

func runSession(ctx context.Context, o options, stdout, stderr io.Writer) error {
	started := time.Now()
	dir := filepath.Join(o.out, started.Format("2006-01-02_150405"))
	rep := session.Report{Started: started, Game: o.game, Goal: o.goal, Snapshot: o.snapshot, Model: o.model}
	coreLog := filepath.Join(o.runs, "core_session.log")
	coreArgs := []string{"-listen", o.listen, "-log", coreLog, "-runs", o.runs, "-states", o.states, "-games", o.games}

	if o.dryRun {
		fmt.Fprintf(stdout, "would make %s\ncore: %s %s\nplay: %s %s\n", dir, o.core, strings.Join(coreArgs, " "),
			o.claude, strings.Join(claudeArgs(o, "<mcp.json>", "", playTools()), " "))
		return nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := portFree(o.listen); err != nil {
		return err
	}

	// 2. Before the model: the snapshot, the segment, the goal.
	core, err := session.StartCore(ctx, o.core, coreArgs)
	if err != nil {
		return err
	}
	hello, err := core.WaitForDriver(ctx, o.wait)
	if err == nil && hello.Driver.Game != o.game {
		err = fmt.Errorf("the driver is %s, not %s", hello.Driver.Game, o.game)
	}
	var seg struct {
		Current struct {
			N int `json:"n"`
		} `json:"current"`
		LogFile string `json:"log_file"`
	}
	var before goalAnswer
	if err == nil {
		rep.Variant = hello.Driver.Variant
		err = core.Call(ctx, "restore", map[string]any{"label": o.snapshot}, nil)
	}
	if err == nil {
		label := fmt.Sprintf("session %s: %s from %s", started.Format("2006-01-02 15:04"), o.goal, o.snapshot)
		err = core.Call(ctx, "segment", map[string]any{"label": label}, &seg)
	}
	if err == nil {
		err = core.Call(ctx, "goal", map[string]any{"id": o.goal}, &before)
	}
	core.Close()
	if err != nil {
		return err
	}
	if before.Goal == nil {
		return fmt.Errorf("the goal tool named no goal %s", o.goal)
	}
	rep.MetBefore = before.Goal.Met
	rep.RunLog = seg.LogFile
	// The core was given -runs as an absolute path, so the log's path is absolute; made so again in case.
	runLog, err := filepath.Abs(seg.LogFile)
	if err != nil {
		return err
	}
	if err := waitPortFree(o.listen, 15*time.Second); err != nil {
		return err
	}

	// The core the session starts carries on the same run log and segment.
	mcpConfig := filepath.Join(dir, "mcp.json")
	cfg := map[string]any{"mcpServers": map[string]any{"autoplay": map[string]any{
		"command": o.core, "args": append(append([]string{}, coreArgs...), "-resume", runLog),
	}}}
	if b, err := json.MarshalIndent(cfg, "", "  "); err != nil {
		return err
	} else if err := os.WriteFile(mcpConfig, b, 0o644); err != nil {
		return err
	}

	vars := map[string]any{
		"Game": o.game, "GameTitle": gameTitle(o.game), "Goal": o.goal, "GoalDescription": before.Goal.Description,
		"RunLog": filepath.Base(runLog), "Date": started.Format("2006-01-02"),
	}

	// 3. Play.
	vars["Budget"] = o.budget
	playText, err := session.Fill(session.PlayPrompt, vars)
	if err != nil {
		return err
	}
	play, err := runClaude(ctx, o, dir, "play", playText, claudeArgs(o, mcpConfig, "", playTools()), o.budget, stderr)
	rep.Phases = append(rep.Phases, play)
	if err != nil {
		rep.Notes = append(rep.Notes, "play: "+err.Error())
	}
	if err := waitPortFree(o.listen, 30*time.Second); err != nil {
		rep.Notes = append(rep.Notes, err.Error())
	}

	// 4. Distill.
	if o.distillBudget > 0 && play.SessionID != "" {
		vars["Budget"] = o.distillBudget
		distillText, err := session.Fill(session.DistillPrompt, vars)
		if err != nil {
			return err
		}
		d, err := runClaude(ctx, o, dir, "distill", distillText,
			claudeArgs(o, mcpConfig, play.SessionID, distillTools(o.game)), o.distillBudget, stderr)
		rep.Phases = append(rep.Phases, d)
		if err != nil {
			rep.Notes = append(rep.Notes, "distill: "+err.Error())
		}
		if err := waitPortFree(o.listen, 30*time.Second); err != nil {
			rep.Notes = append(rep.Notes, err.Error())
		}
	}

	// 5. After the model: close the segment, check the goal, read where the game is.
	core, err = session.StartCore(ctx, o.core, append(append([]string{}, coreArgs...), "-resume", runLog))
	if err != nil {
		return err
	}
	var closed struct {
		Closed struct {
			N int `json:"n"`
		} `json:"closed"`
	}
	var after goalAnswer
	var where struct {
		Location any   `json:"location"`
		Badges   []int `json:"badges"`
		Money    int   `json:"money"`
		Party    []struct {
			Species string `json:"species"`
			Level   int    `json:"level"`
			HP      int    `json:"hp"`
			MaxHP   int    `json:"max_hp"`
		} `json:"party"`
	}
	_, err = core.WaitForDriver(ctx, o.wait)
	if err == nil {
		err = core.Call(ctx, "segment", map[string]any{"label": "after " + o.goal + " session " + started.Format("15:04")}, &closed)
	}
	if err == nil {
		err = core.Call(ctx, "goal", map[string]any{"id": o.goal}, &after)
	}
	if err == nil {
		err = core.Call(ctx, "observe", nil, &where)
	}
	core.Close()
	if err != nil {
		rep.Notes = append(rep.Notes, "after the session: "+err.Error())
	}
	if after.Goal != nil {
		rep.MetAfter, rep.Failed = after.Goal.Met, after.Goal.Failed
	}
	loc, _ := json.Marshal(where.Location)
	party := []string{}
	for _, p := range where.Party {
		party = append(party, fmt.Sprintf("%s Lv %d %d/%d", p.Species, p.Level, p.HP, p.MaxHP))
	}
	rep.Where = fmt.Sprintf("%s, badges %v, money %d, party %s", loc, where.Badges, where.Money, strings.Join(party, ", "))

	// 6. The report.
	if sum, err := session.SummarizeRunLog(runLog, seg.Current.N, seg.Current.N); err == nil {
		rep.Run = sum
	} else {
		rep.Notes = append(rep.Notes, "the run log: "+err.Error())
	}
	knowledge := filepath.Join("autoplay", "games", o.game)
	if stat, err := gitOut(o.repo, "diff", "--stat", "--", knowledge); err == nil {
		rep.Knowledge = stat
		untracked, _ := gitOut(o.repo, "ls-files", "--others", "--exclude-standard", "--", knowledge)
		if strings.TrimSpace(untracked) != "" {
			rep.Knowledge += "\nnew files: " + strings.Join(strings.Fields(untracked), ", ")
		}
		if diff, err := gitOut(o.repo, "diff", "--", knowledge); err == nil {
			os.WriteFile(filepath.Join(dir, "knowledge.diff"), []byte(diff), 0o644)
		}
	} else {
		rep.Notes = append(rep.Notes, "git diff: "+err.Error())
	}
	if err := rep.Write(dir); err != nil {
		return err
	}
	fmt.Fprintln(stdout, rep.Markdown())
	fmt.Fprintf(stdout, "report: %s\n", filepath.Join(dir, "report.md"))
	return nil
}

func playTools() []string {
	return []string{"mcp__autoplay__*", "Read", "Glob", "Grep"}
}

// distillTools can read anything in the repository and edit only the game's knowledge store.
func distillTools(game string) []string {
	k := "autoplay/games/" + game + "/**"
	return []string{"Read", "Glob", "Grep", "Edit(" + k + ")", "Write(" + k + ")"}
}

// claudeArgs is a headless run: the prompt on stdin, stream-json out, this core as the only MCP server, tools not
// allowed denied rather than asked about. Never --bare (it takes an API key only) and never a dollar budget.
func claudeArgs(o options, mcpConfig, resume string, tools []string) []string {
	// dontAsk still ran read-only shell commands the allow list left out (the first session's distill: `wc -c` in Bash, `git
	// diff` in PowerShell, 2026-09-17), so the shells are denied by name.
	args := []string{"-p", "--output-format", "stream-json", "--verbose", "--strict-mcp-config", "--mcp-config", mcpConfig,
		"--permission-mode", "dontAsk", "--allowedTools", strings.Join(tools, ","), "--disallowedTools", "Bash,PowerShell"}
	if o.model != "" {
		args = append(args, "--model", o.model)
	}
	if resume != "" {
		args = append(args, "--resume", resume)
	}
	return args
}

// runClaude runs one headless phase, its stream copied to <dir>/<name>.ndjson, and stops it at budget model calls.
func runClaude(ctx context.Context, o options, dir, name, prompt string, args []string, budget int, stderr io.Writer) (ph session.Phase, err error) {
	ph = session.Phase{Name: name, Budget: budget}
	start := time.Now()
	defer func() { ph.Wall = time.Since(start) }() // a named result, so the deferred write reaches the caller
	streamFile, err := os.Create(filepath.Join(dir, name+".ndjson"))
	if err != nil {
		return ph, err
	}
	defer streamFile.Close()
	var errBuf bytes.Buffer
	cmd := exec.Command(o.claude, args...)
	cmd.Dir = o.repo
	cmd.Env = session.ChildEnv(os.Environ())
	cmd.Stdin = strings.NewReader(prompt)
	cmd.Stderr = io.MultiWriter(&errBuf, stderr)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return ph, err
	}
	if err := cmd.Start(); err != nil {
		return ph, fmt.Errorf("start %s: %w", o.claude, err)
	}
	var once sync.Once
	stopAtBudget := func() {
		once.Do(func() {
			ph.StoppedAtBudget = true
			killTree(cmd.Process.Pid)
		})
	}
	go func() {
		<-ctx.Done()
		once.Do(func() { killTree(cmd.Process.Pid) })
	}()
	c := session.NewCounter()
	readErr := c.Read(out, streamFile, func(calls int) {
		if calls >= budget {
			stopAtBudget()
		}
	})
	waitErr := cmd.Wait()
	ph.ModelCalls, ph.ToolUses, ph.SessionID, ph.LastText = c.Calls(), c.ToolUses, c.SessionID, clip(c.LastText, 500)
	switch {
	case c.Result != nil:
		ph.Ended, ph.NumTurns = c.Result.Subtype, c.Result.NumTurns
		if c.Result.IsError {
			ph.Ended += " (error)"
		}
	case ph.StoppedAtBudget:
		ph.Ended = "stopped at the budget"
	default:
		ph.Ended = "no result line"
	}
	if readErr != nil {
		return ph, readErr
	}
	if waitErr != nil && !ph.StoppedAtBudget && c.Result == nil {
		return ph, fmt.Errorf("%s: %w (%s)", name, waitErr, clip(errBuf.String(), 500))
	}
	return ph, nil
}

// killTree stops a process and the processes it started (the MCP server it runs), which a plain kill leaves behind on
// Windows, where they would keep the driver's port.
func killTree(pid int) {
	if runtime.GOOS == "windows" {
		exec.Command("taskkill", "/T", "/F", "/PID", fmt.Sprint(pid)).Run()
		return
	}
	if p, err := os.FindProcess(pid); err == nil {
		p.Kill()
	}
}

func portFree(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("%s is in use: another core is running on the driver's port", addr)
	}
	return ln.Close()
}

func waitPortFree(addr string, wait time.Duration) error {
	deadline := time.Now().Add(wait)
	for {
		err := portFree(addr)
		if err == nil || time.Now().After(deadline) {
			return err
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func gameTitle(game string) string {
	switch game {
	case "emerald":
		return "Pokémon Emerald (vanilla)"
	case "crystal":
		return "Pokémon Crystal (vanilla)"
	}
	return game
}

func gitOut(repo string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", repo}, args...)...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return "", errors.New(strings.TrimSpace(errb.String()))
	}
	return out.String(), nil
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n] + "..."
	}
	return s
}
