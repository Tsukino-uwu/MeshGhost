package main

import (
	"strings"
	"testing"
)

// TestRoomCodeHelpSaysTheFlagIsTheLeakierSpelling is review F21 (2026-09-08).
//
// -room-code puts a shared secret into this process's command line, which every
// other local process can read and which the host's shell writes to its history
// file. The help text pointed at config.json as the friendlier option and never
// said the flag form was the leakier one, so a host reading -help had no reason
// to take the hint. The flag is not going away, so the help text is the fix and
// this test is what keeps it from being trimmed back to "see config.json".
func TestRoomCodeHelpSaysTheFlagIsTheLeakierSpelling(t *testing.T) {
	help := strings.ToLower(roomCodeFlagHelp)
	// The recommendation, and the mechanism -- either half alone is the text
	// that already stood: config.json was named, the leak was not.
	for _, want := range []string{"config.json", "command line", "history"} {
		if !strings.Contains(help, want) {
			t.Errorf("-room-code help does not mention %q; a host is told to prefer config.json without being told why\nhelp: %s", want, roomCodeFlagHelp)
		}
	}
	// Named in terms a host can act on: the tools that show them the leak.
	if !strings.Contains(help, "get-process") && !strings.Contains(help, "ps") && !strings.Contains(help, "/proc") {
		t.Errorf("-room-code help names no way to SEE the leak (Get-Process, ps, /proc)\nhelp: %s", roomCodeFlagHelp)
	}
	// The pre-existing warnings are load-bearing and must survive the rewrite:
	// what running open means, and that the code is plaintext without TLS.
	for _, want := range []string{"open", "plaintext"} {
		if !strings.Contains(help, want) {
			t.Errorf("-room-code help lost its %q warning in the F21 rewrite\nhelp: %s", want, roomCodeFlagHelp)
		}
	}
}
