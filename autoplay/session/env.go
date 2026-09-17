package session

import (
	"fmt"
	"strings"
)

// BillingVars are the environment variables that would move a headless Claude Code session off the user's
// subscription: an API key or token, or a cloud provider. The launcher refuses to start while any is set, and
// leaves every one out of the session's environment.
var BillingVars = []string{
	"ANTHROPIC_API_KEY",
	"ANTHROPIC_AUTH_TOKEN",
	"CLAUDE_CODE_USE_BEDROCK",
	"CLAUDE_CODE_USE_VERTEX",
	"CLAUDE_CODE_USE_FOUNDRY",
}

// CheckEnv refuses an environment that sets any of BillingVars, naming each (never its value).
func CheckEnv(environ []string) error {
	var set []string
	for _, kv := range environ {
		name, value, _ := strings.Cut(kv, "=")
		if isBillingVar(name) && value != "" {
			set = append(set, name)
		}
	}
	if len(set) > 0 {
		return fmt.Errorf("refusing to start: %s set, which would bill an API account instead of the Claude subscription; unset it first",
			strings.Join(set, ", "))
	}
	return nil
}

// SessionMarkers are variables a Claude Code session sets for the processes it starts (read from a launching shell's
// environment, 2026-09-17). A launcher run from inside a session would hand them on, tying the headless session to the
// one that launched it; its other settings (a Git Bash path, say) are kept.
var SessionMarkers = []string{
	"CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_AGENT_SDK_VERSION",
	"CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED",
	"CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH",
	"CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING", "CLAUDE_CODE_ENABLE_TASKS",
}

// ChildEnv is environ with every BillingVars and SessionMarkers entry left out.
func ChildEnv(environ []string) []string {
	var out []string
	for _, kv := range environ {
		name, _, _ := strings.Cut(kv, "=")
		if isBillingVar(name) || isMarker(name) {
			continue
		}
		out = append(out, kv)
	}
	return out
}

func isMarker(name string) bool {
	for _, v := range SessionMarkers {
		if strings.EqualFold(name, v) {
			return true
		}
	}
	return false
}

func isBillingVar(name string) bool {
	for _, v := range BillingVars {
		if strings.EqualFold(name, v) {
			return true
		}
	}
	return false
}
