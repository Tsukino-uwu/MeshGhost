package session

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/runlog"
)

func TestCheckEnvRefusesEveryBillingVariable(t *testing.T) {
	if err := CheckEnv([]string{"PATH=x", "HOME=y", "ANTHROPIC_API_KEY="}); err != nil {
		t.Fatalf("an empty key refused: %v", err)
	}
	for _, v := range BillingVars {
		err := CheckEnv([]string{"PATH=x", v + "=secret-value"})
		if err == nil || !strings.Contains(err.Error(), v) || strings.Contains(err.Error(), "secret-value") {
			t.Errorf("%s: CheckEnv = %v", v, err)
		}
	}
	if err := CheckEnv([]string{"anthropic_api_key=k"}); err == nil {
		t.Error("a lowercase name passed (Windows names are case-blind)")
	}
}

func TestChildEnvLeavesOutBillingAndSessionMarkers(t *testing.T) {
	in := []string{"PATH=x", "ANTHROPIC_API_KEY=k", "CLAUDECODE=1", "CLAUDE_CODE_SESSION_ID=abc",
		"CLAUDE_CODE_GIT_BASH_PATH=C:/git/bin/bash.exe", "MCP_TOOL_TIMEOUT=900000"}
	got := strings.Join(ChildEnv(in), " ")
	if got != "PATH=x CLAUDE_CODE_GIT_BASH_PATH=C:/git/bin/bash.exe MCP_TOOL_TIMEOUT=900000" {
		t.Fatalf("ChildEnv = %s", got)
	}
}

func TestSummarizeRunLog(t *testing.T) {
	dir := t.TempDir()
	l, err := runlog.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	l.Call("restore", map[string]any{"label": "x"}, nil, "restore")
	l.Begin("session: play")
	l.Call("status", nil, nil, "")
	l.CallOutcome("goto", nil, nil, "", "spotted")
	l.CallOutcome("battle", nil, nil, "", "ended")
	l.CallOutcome("goto", nil, nil, "", "unreachable")
	l.CallOutcome("run_skill", nil, nil, "", "no_rule")
	l.Call("cheat", nil, errors.New("refused"), "cheat:warp")
	path := l.Path()
	l.Close() // a core stopping: the segment carries on
	l, err = runlog.Resume(path)
	if err != nil {
		t.Fatal(err)
	}
	l.Call("exec", nil, nil, "exec")
	l.Begin("after the session")
	l.Close()

	s, err := SummarizeRunLog(path, 2, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Segments) != 2 || s.Segments[0].N != 2 || s.Segments[0].Claim != "reached" || s.Segments[0].Ended == nil {
		t.Fatalf("segments = %+v", s.Segments)
	}
	if s.TotalCalls != 6 || s.Calls["goto"] != 2 || s.Calls["status"] != 0 || s.Refused != 1 {
		t.Fatalf("calls = %v (total %d, refused %d)", s.Calls, s.TotalCalls, s.Refused)
	}
	if s.Stops["unreachable"] != 1 || s.Stops["no_rule"] != 1 || s.Stops["spotted"] != 0 || s.Outcomes["ended"] != 1 {
		t.Fatalf("outcomes %v, stops %v", s.Outcomes, s.Stops)
	}
	if len(s.ReachedBy) != 1 || s.ReachedBy[0] != "segment 2: exec" {
		t.Fatalf("reached by = %v (the restore was before segment 2, the refused cheat reached nothing)", s.ReachedBy)
	}

	if only, err := SummarizeRunLog(path, 3, 3); err != nil || len(only.Segments) != 1 || only.TotalCalls != 0 {
		t.Fatalf("segment 3 alone = %+v, %v", only, err)
	}
	if _, err := SummarizeRunLog(filepath.Join(dir, "missing.ndjson"), 1, 0); !os.IsNotExist(err) {
		t.Fatalf("a missing log: %v", err)
	}
}

func TestCounterCountsResponsesNotLines(t *testing.T) {
	stream := strings.Join([]string{
		`{"type":"system","subtype":"init","session_id":"s1","model":"m"}`,
		`{"type":"assistant","session_id":"s1","message":{"id":"msg_1","content":[{"type":"text","text":"reading"}]}}`,
		`{"type":"assistant","session_id":"s1","message":{"id":"msg_1","content":[{"type":"tool_use","name":"Read"}]}}`,
		`{"type":"user","session_id":"s1","message":{"content":[{"type":"tool_result"}]}}`,
		`{"type":"assistant","session_id":"s1","message":{"id":"msg_2","content":[{"type":"tool_use","name":"mcp__autoplay__goal"}]}}`,
		`not json`,
		`{"type":"assistant","session_id":"s1","message":{"id":"msg_3","content":[{"type":"text","text":"GOAL MET"}]}}`,
		`{"type":"result","subtype":"success","is_error":false,"num_turns":3,"result":"GOAL MET","session_id":"s1","total_cost_usd":1}`,
	}, "\n")
	c := NewCounter()
	var seen []int
	var copied strings.Builder
	if err := c.Read(strings.NewReader(stream), &copied, func(n int) { seen = append(seen, n) }); err != nil {
		t.Fatal(err)
	}
	if c.Calls() != 3 || len(seen) != 3 || seen[2] != 3 || c.SessionID != "s1" {
		t.Fatalf("calls %d, seen %v, session %q", c.Calls(), seen, c.SessionID)
	}
	if c.ToolUses["Read"] != 1 || c.ToolUses["mcp__autoplay__goal"] != 1 || c.LastText != "GOAL MET" {
		t.Fatalf("tool uses %v, last text %q", c.ToolUses, c.LastText)
	}
	if c.Result == nil || c.Result.NumTurns != 3 || c.Result.Subtype != "success" || copied.String() != stream {
		t.Fatalf("result %+v", c.Result)
	}
}

func TestThePromptsFill(t *testing.T) {
	vars := map[string]any{"Game": "emerald", "GameTitle": "Pokémon Emerald (vanilla)", "Goal": "story_heat_badge",
		"GoalDescription": "the fourth badge", "Budget": 400, "Date": "2026-09-17"}
	for name, text := range map[string]string{"play": PlayPrompt, "distill": DistillPrompt} {
		got, err := Fill(text, vars)
		if err != nil || strings.Contains(got, "{{") || strings.Contains(got, "<no value>") {
			t.Errorf("%s: %v\n%s", name, err, got)
		}
	}
	if !strings.Contains(PlayPrompt, "GOAL MET") || !strings.Contains(DistillPrompt, "DISTILLED") {
		t.Error("a prompt lost the line its phase ends on")
	}
	if _, err := Fill(PlayPrompt, map[string]any{"Game": "emerald"}); err == nil {
		t.Error("a missing field filled silently")
	}
}
