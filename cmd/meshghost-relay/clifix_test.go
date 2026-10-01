package main

import (
	"strings"
	"testing"
)

// TestRoomCodeHelpSaysTheFlagIsTheLeakierSpelling: -room-code puts the secret in the command line, which every local
// process can read and the shell writes to its history, so the help must say why config.json is better.
func TestRoomCodeHelpSaysTheFlagIsTheLeakierSpelling(t *testing.T) {
	help := strings.ToLower(roomCodeFlagHelp)
	for _, want := range []string{"config.json", "command line", "history"} {
		if !strings.Contains(help, want) {
			t.Errorf("-room-code help does not mention %q; a host is told to prefer config.json without being told why\nhelp: %s", want, roomCodeFlagHelp)
		}
	}
	// The tools that show a host the leak.
	if !strings.Contains(help, "get-process") && !strings.Contains(help, "ps") && !strings.Contains(help, "/proc") {
		t.Errorf("-room-code help names no way to SEE the leak (Get-Process, ps, /proc)\nhelp: %s", roomCodeFlagHelp)
	}
	// What running open means, and that the code is plaintext without TLS.
	for _, want := range []string{"open", "plaintext"} {
		if !strings.Contains(help, want) {
			t.Errorf("-room-code help lost its %q warning in the F21 rewrite\nhelp: %s", want, roomCodeFlagHelp)
		}
	}
}
