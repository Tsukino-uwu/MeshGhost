package main

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
)

// The headless session is named for the other sessions on the machine and holds their messages, so a chat can watch
// it go idle and nothing a chat sends reaches the model mid-goal (2026-09-22).
func TestClaudeArgsNamesAndHoldsTheSession(t *testing.T) {
	o := options{game: "tevi", listen: "127.0.0.1:7872"}
	args := claudeArgs(o, "<mcp.json>", "", playTools())
	after := func(flag string) string {
		i := slices.Index(args, flag)
		if i < 0 || i+1 >= len(args) {
			t.Fatalf("%s missing from %q", flag, args)
		}
		return args[i+1]
	}
	if got := after("--name"); got != "autoplay-tevi-7872" {
		t.Errorf("--name %q, want autoplay-tevi-7872", got)
	}
	var settings struct {
		Inbound string `json:"crossSessionInbound"`
	}
	if err := json.Unmarshal([]byte(after("--settings")), &settings); err != nil {
		t.Fatalf("--settings does not parse: %v", err)
	}
	if settings.Inbound != "hold" {
		t.Errorf("crossSessionInbound %q, want hold", settings.Inbound)
	}
	for _, never := range []string{"--bare", "--max-budget-usd"} {
		if slices.Contains(args, never) {
			t.Errorf("%s must never be passed: %q", never, args)
		}
	}
	for _, must := range []string{"--strict-mcp-config", "--permission-mode"} {
		if !slices.Contains(args, must) {
			t.Errorf("%s missing from %q", must, args)
		}
	}
	if !strings.Contains(after("--disallowedTools"), "Bash") {
		t.Errorf("the shells stay denied: %q", args)
	}
}

func TestSessionNameFallsBackToTheWholeListen(t *testing.T) {
	if got := sessionName(options{game: "emerald", listen: "7870"}); got != "autoplay-emerald-7870" {
		t.Errorf("got %q", got)
	}
}
