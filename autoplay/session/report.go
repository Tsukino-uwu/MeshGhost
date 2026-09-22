package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Phase is one headless run of Claude Code within a session: the play, then the distillation.
type Phase struct {
	Name string `json:"name"`
	// ModelCalls counts the model's responses: distinct message ids in the stream. Every line of one id carried the same
	// output-token usage, and one id held five tool uses made together (the dry run, 2026-09-17). NumTurns is the result
	// line's own count, which on that run was each tool use and the closing text (10 against 4 responses): not calls.
	ModelCalls int            `json:"model_calls"`
	NumTurns   int            `json:"num_turns,omitempty"`
	ToolUses   map[string]int `json:"tool_uses"`
	Budget     int            `json:"budget"`
	// StoppedAtBudget is true when the launcher stopped the run because it reached its budget.
	StoppedAtBudget bool          `json:"stopped_at_budget,omitempty"`
	Ended           string        `json:"ended"` // the result line's subtype, or why there was none
	LastText        string        `json:"last_text,omitempty"`
	Wall            time.Duration `json:"wall"`
	SessionID       string        `json:"session_id,omitempty"`
}

// Report is a session's record, written beside its stream as JSON and as Markdown.
type Report struct {
	Started  time.Time `json:"started"`
	Game     string    `json:"game"`
	Variant  string    `json:"variant"`
	Goal     string    `json:"goal"`
	Snapshot string    `json:"snapshot"`
	Model    string    `json:"model"`
	// Name is what other Claude Code sessions saw the run as (the launcher's --name; the CLI varies a taken name).
	Name   string `json:"session_name"`
	RunLog string `json:"run_log"`
	// MetBefore and MetAfter are the launcher's own goal checks, with no model.
	MetBefore bool       `json:"met_before"`
	MetAfter  bool       `json:"met_after"`
	Failed    []string   `json:"failed_after,omitempty"`
	Where     string     `json:"where_after"`
	Phases    []Phase    `json:"phases"`
	Run       RunSummary `json:"run"`
	// Knowledge is `git diff --stat` of the game's knowledge store after the session.
	Knowledge string   `json:"knowledge_diff_stat"`
	Notes     []string `json:"notes,omitempty"`
}

// Write saves the report as report.json and report.md in dir.
func (r Report) Write(dir string) error {
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "report.json"), b, 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "report.md"), []byte(r.Markdown()), 0o644)
}

// Markdown is the short report the plan asks for: goal and result, walked or reached, cheats, stops, new facts, calls.
func (r Report) Markdown() string {
	var b strings.Builder
	result := "NOT met"
	if r.MetAfter {
		result = "met"
	}
	if r.MetBefore {
		result += " (already met before the session)"
	}
	fmt.Fprintf(&b, "# Session %s: %s\n\n", r.Started.Format("2006-01-02 15:04"), r.Goal)
	fmt.Fprintf(&b, "- **Goal** `%s` from snapshot `%s`, %s %s, model %s: **%s**, checked by the launcher with no model.\n",
		r.Goal, r.Snapshot, r.Game, r.Variant, orDefault(r.Model), result)
	if r.Name != "" {
		fmt.Fprintf(&b, "- **Session name** `%s` to the other Claude Code sessions on this machine; their messages were held.\n", r.Name)
	}
	if len(r.Failed) > 0 {
		fmt.Fprintf(&b, "- **Not met because**: %s\n", strings.Join(r.Failed, "; "))
	}
	fmt.Fprintf(&b, "- **Where the game was left**: %s\n", r.Where)
	for _, p := range r.Phases {
		stop := ""
		if p.StoppedAtBudget {
			stop = ", stopped at its budget"
		}
		fmt.Fprintf(&b, "- **%s**: %d model calls (responses) of %d%s; the result line's num_turns %d, ended %s; %s. Tools: %s\n",
			p.Name, p.ModelCalls, p.Budget, stop, p.NumTurns, p.Ended, p.Wall.Round(time.Second), counts(p.ToolUses))
	}
	fmt.Fprintf(&b, "- **Game tool calls** (status left out): %d, %d refused. By tool: %s\n", r.Run.TotalCalls, r.Run.Refused, counts(r.Run.Calls))
	fmt.Fprintf(&b, "- **Stops**: %s\n", orNone(counts(r.Run.Stops)))
	fmt.Fprintf(&b, "- **Cheats, restores and exec**: %s\n", orNone(strings.Join(r.Run.ReachedBy, "; ")))
	b.WriteString("- **Segments**:\n")
	for _, s := range r.Run.Segments {
		because := ""
		if len(s.Because) > 0 {
			because = " (" + strings.Join(s.Because, ", ") + ")"
		}
		fmt.Fprintf(&b, "  - %d %s%s: %s\n", s.N, s.Claim, because, s.Label)
	}
	fmt.Fprintf(&b, "- **Knowledge store changed**: %s\n", orNone(strings.TrimSpace(r.Knowledge)))
	fmt.Fprintf(&b, "- **Run log**: `%s`\n", r.RunLog)
	for _, n := range r.Notes {
		fmt.Fprintf(&b, "- %s\n", n)
	}
	return b.String()
}

func counts(m map[string]int) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s %d", k, m[k]))
	}
	return strings.Join(parts, ", ")
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

func orDefault(s string) string {
	if s == "" {
		return "(the account's default)"
	}
	return s
}
