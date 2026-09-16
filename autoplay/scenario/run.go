package scenario

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Caller makes one tool call and returns the answer's text, and whether the tool answered with an
// error. err is for the call itself failing (the server gone), never for a tool's own refusal.
type Caller interface {
	Call(ctx context.Context, tool string, args map[string]any) (text string, isError bool, err error)
}

// SessionCaller calls tools over an MCP client session: the runner's way into a server, in-process or not.
type SessionCaller struct{ Session *mcp.ClientSession }

// Call implements Caller.
func (c SessionCaller) Call(ctx context.Context, tool string, args map[string]any) (string, bool, error) {
	if args == nil {
		args = map[string]any{}
	}
	res, err := c.Session.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		return "", false, err
	}
	var b strings.Builder
	for _, content := range res.Content {
		if tc, ok := content.(*mcp.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	return b.String(), res.IsError, nil
}

// Options change how Run runs a scenario. The zero value runs it as the file says and prints nothing.
type Options struct {
	// Repeat, when above 0, replaces the file's repeat.
	Repeat int
	// All runs every repeat even after one fails; by default the first failed run ends it.
	All bool
	// Out receives a line per step and per run as they happen.
	Out io.Writer
}

// Failure says where a run stopped and why.
type Failure struct {
	Phase  string `json:"phase"` // "setup" or "steps"
	Step   int    `json:"step"`  // 1-based
	Tool   string `json:"tool"`
	Reason string `json:"reason"`
}

// RunReport is one run of a scenario.
type RunReport struct {
	N       int           `json:"n"`
	Passed  bool          `json:"passed"`
	Failure *Failure      `json:"failure,omitempty"`
	Elapsed time.Duration `json:"elapsed"`
	// StepsClaim is the run log's label for the steps' segment, "walked" or "reached"; empty when the
	// server keeps no run log.
	StepsClaim string `json:"steps_claim,omitempty"`
}

// Report is every run of one scenario.
type Report struct {
	Name   string      `json:"name"`
	Want   int         `json:"want"`
	Runs   []RunReport `json:"runs"`
	Passed int         `json:"passed"`
}

// OK is true when every run wanted ran and passed.
func (r Report) OK() bool { return r.Passed == r.Want && len(r.Runs) == r.Want }

// ErrRefused wraps a reason a scenario cannot be run at all against what is connected: no driver, or
// another game. That is not a failed run: nothing was tried.
var ErrRefused = errors.New("scenario refused")

// Run checks the connected driver against the scenario, then runs it. A failed step ends its run; a
// failed run ends the scenario unless opts.All. The error is for a refusal or the server failing, never
// for a run that failed, which the report holds.
func Run(ctx context.Context, c Caller, s *Scenario, opts Options) (Report, error) {
	out := opts.Out
	if out == nil {
		out = io.Discard
	}
	want := s.Repeat
	if opts.Repeat > 0 {
		want = opts.Repeat
	}
	rep := Report{Name: s.Name, Want: want}
	if err := checkDriver(ctx, c, s); err != nil {
		return rep, err
	}
	fmt.Fprintf(out, "scenario %s: %d run(s)\n", s.Name, want)
	if s.Reproduces != "" {
		fmt.Fprintf(out, "  reproduces: %s\n", s.Reproduces)
	}
	for n := 1; n <= want; n++ {
		run, err := runOnce(ctx, c, s, n, want, out)
		rep.Runs = append(rep.Runs, run)
		if err != nil {
			return rep, err
		}
		if run.Passed {
			rep.Passed++
			fmt.Fprintf(out, "run %d/%d PASS in %s (steps %s)\n", n, want, run.Elapsed.Round(time.Millisecond), orUnknown(run.StepsClaim))
		} else {
			f := run.Failure
			fmt.Fprintf(out, "run %d/%d FAIL at %s %d (%s): %s\n", n, want, f.Phase, f.Step, f.Tool, f.Reason)
			if !opts.All {
				break
			}
		}
	}
	verdict := "PASS"
	if !rep.OK() {
		verdict = "FAIL"
	}
	fmt.Fprintf(out, "%s: %s, %d of %d run(s) passed\n", s.Name, verdict, rep.Passed, want)
	return rep, nil
}

func orUnknown(claim string) string {
	if claim == "" {
		return "unlabelled"
	}
	return claim
}

func checkDriver(ctx context.Context, c Caller, s *Scenario) error {
	text, isErr, err := c.Call(ctx, "status", nil)
	if err != nil {
		return err
	}
	if isErr {
		return fmt.Errorf("%w: status answered an error: %s", ErrRefused, text)
	}
	var st struct {
		Connected bool `json:"connected"`
		Driver    *struct {
			Game    string `json:"game"`
			Variant string `json:"variant"`
		} `json:"driver"`
	}
	if err := json.Unmarshal([]byte(text), &st); err != nil {
		return fmt.Errorf("status answered something that does not parse: %w", err)
	}
	if !st.Connected || st.Driver == nil {
		return fmt.Errorf("%w: no driver is connected", ErrRefused)
	}
	if st.Driver.Game != s.Game {
		return fmt.Errorf("%w: %s is for %s, and the driver is %s", ErrRefused, s.Name, s.Game, st.Driver.Game)
	}
	if s.Variant != "" && st.Driver.Variant != s.Variant {
		return fmt.Errorf("%w: %s is for the %s variant, and the driver says %q", ErrRefused, s.Name, s.Variant, st.Driver.Variant)
	}
	return nil
}

// runOnce makes one run: a segment for the setup, one for the steps, and a third opened after, so the
// steps' segment is closed with its claim.
func runOnce(ctx context.Context, c Caller, s *Scenario, n, of int, out io.Writer) (RunReport, error) {
	run := RunReport{N: n}
	start := time.Now()
	label := fmt.Sprintf("scenario %s run %d/%d", s.Name, n, of)

	if _, err := segment(ctx, c, label+": setup"); err != nil {
		return run, err
	}
	failure, err := runPhase(ctx, c, "setup", s.Setup, out)
	if err != nil || failure != nil {
		run.Failure, run.Elapsed = failure, time.Since(start)
		return run, err
	}
	if _, err := segment(ctx, c, label+": steps"); err != nil {
		run.Elapsed = time.Since(start)
		return run, err
	}
	failure, err = runPhase(ctx, c, "steps", s.Steps, out)
	claim, segErr := segment(ctx, c, "after "+label)
	run.StepsClaim, run.Failure, run.Passed, run.Elapsed = claim, failure, err == nil && failure == nil, time.Since(start)
	if err == nil {
		err = segErr
	}
	return run, err
}

func runPhase(ctx context.Context, c Caller, phase string, steps []Step, out io.Writer) (*Failure, error) {
	for i, st := range steps {
		fail := func(reason string) *Failure {
			fmt.Fprintf(out, "  %s %d %s: FAIL %s\n", phase, i+1, st.Tool, reason)
			return &Failure{Phase: phase, Step: i + 1, Tool: st.Tool, Reason: reason}
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		text, isErr, err := c.Call(ctx, st.Tool, st.Args)
		if err != nil {
			return nil, fmt.Errorf("%s %d (%s): %w", phase, i+1, st.Tool, err)
		}
		if st.Error != "" {
			if !isErr {
				return fail(fmt.Sprintf("want an error containing %q, and it answered", st.Error)), nil
			}
			if !strings.Contains(text, st.Error) {
				return fail(fmt.Sprintf("want an error containing %q, got %q", st.Error, clip(text))), nil
			}
			fmt.Fprintf(out, "  %s %d %s: ok (refused as expected)\n", phase, i+1, st.Tool)
			continue
		}
		if isErr {
			return fail("the tool answered an error: " + clip(text)), nil
		}
		var answer any
		if len(st.Expect) > 0 {
			if err := json.Unmarshal([]byte(text), &answer); err != nil {
				return fail("the answer is not JSON: " + clip(text)), nil
			}
		}
		for _, e := range st.Expect {
			if why := e.Check(answer); why != "" {
				return fail(why), nil
			}
		}
		fmt.Fprintf(out, "  %s %d %s: ok%s\n", phase, i+1, st.Tool, checked(len(st.Expect)))
	}
	return nil, nil
}

func checked(n int) string {
	if n == 0 {
		return ""
	}
	return fmt.Sprintf(" (%d check(s))", n)
}

func clip(s string) string {
	if len(s) > ShowLimit {
		return s[:ShowLimit] + "..."
	}
	return s
}

// segment begins a labelled segment and returns the claim of the one it closed. A server with no run
// log refuses the tool; that leaves the claims empty rather than failing the run.
func segment(ctx context.Context, c Caller, label string) (string, error) {
	text, isErr, err := c.Call(ctx, "segment", map[string]any{"label": label})
	if err != nil || isErr {
		return "", err
	}
	var seg struct {
		Closed struct {
			Claim string `json:"claim"`
		} `json:"closed"`
	}
	json.Unmarshal([]byte(text), &seg)
	return seg.Closed.Claim, nil
}
