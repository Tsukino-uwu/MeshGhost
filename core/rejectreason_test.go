package core

import (
	"net"
	"strings"
	"testing"
	"time"
)

// THE REJECT REASON IS A CONTRACT WITH FOUR ADAPTERS, AND NOTHING PINNED IT UNTIL NOW.
//
// When a core cannot reach the relay it refuses the adapter that just attached, passing the dial
// error through as the reject reason. All four shipped adapters branch on that text: each looks
// for the substring "relay" to tell "this core cannot reach the relay" apart from "this core
// already has a game", because the correct response to the two is opposite -- wait on the same
// core, versus walk to the next port.
//
// Getting that distinction wrong is not theoretical. Three of the four adapters lacked it until
// 2026-08-28 and the symptom reached a real user: with the relay down, each rejection cooled
// another port until the whole range was marked and the sweep reported "NO free port to start a
// core on". Crystal had the guard since 2026-08-19; the other three did not.
//
// So the WORD matters now. Reword core's dial error to "could not connect to the server" and all
// four adapters silently revert to the behaviour that broke that user's session -- with every
// other Go test still green, because nothing else looks at this string. This test is what makes
// that rewording fail loudly instead.
//
// It deliberately asserts the weakest useful thing: that the reason mentions the relay at all,
// case-insensitively. It is not a golden-string test and must not become one -- the message is
// meant to stay human-readable and improvable. What may not change is that it says "relay".
func TestARelayFailureRejectionSaysRelay(t *testing.T) {
	// A port nothing is listening on: bind one, learn its number, release it. Better than a
	// hardcoded "surely nothing is here" port, which is exactly the assumption that makes a test
	// flaky on somebody else's machine.
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve a port: %v", err)
	}
	dead := probe.Addr().String()
	if err := probe.Close(); err != nil {
		t.Fatalf("release the probe port: %v", err)
	}

	c := &Core{RelayAddr: dead, DialTimeout: 500 * time.Millisecond}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for the bridge: %v", err)
	}
	defer ln.Close()
	go c.ServeBridge(ln)

	fa := dialFakeAdapter(t, ln.Addr().String())
	fa.hello("anygame")

	// awaitReject fails the test if the hello is ACCEPTED, or if nothing arrives at all, so
	// reaching the check below already means the core refused and told the adapter something.
	reason := fa.awaitReject()
	if !strings.Contains(strings.ToLower(reason), "relay") {
		t.Fatalf("a relay-dial failure was reported to the adapter as %q, which does not mention the "+
			"relay. All four adapters match the substring \"relay\" in this reason to tell a downed "+
			"relay apart from a busy core, and they do OPPOSITE things in the two cases. If this "+
			"message is being reworded, update every adapter's reject handling in the same commit -- "+
			"see the 2026-08-28 entries in both BridgeClient files and both Lua adapters.", reason)
	}
}
