package core

import (
	"bytes"
	"log"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// captureLog redirects the standard logger for one call and returns what it wrote.
func captureLog(t *testing.T, f func()) string {
	t.Helper()
	var buf bytes.Buffer
	prevOut, prevFlags := log.Writer(), log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(prevOut); log.SetFlags(prevFlags) })
	f()
	return buf.String()
}

// A SESSION THAT ENDS UP ON TCP MUST SAY SO.
//
// Found in a Proton tester's log, not by reasoning: sixteen "using quic" lines across eight
// game launches, every one of them followed by the dial failing and the session falling back
// to tcp -- and not one line naming tcp. chooseTransport returned at its `want == netx.TCP`
// branch, which sat ABOVE the log.Printf that announces the choice, so the tcp path was
// silent. The only evidence of the transport actually in use was the "read tcp ..." inside a
// later DISCONNECT message, which means the transport could be learned only from a failure,
// and only by someone who knew to look there.
func TestFallingBackToTCPIsLogged(t *testing.T) {
	offers := []protocol.TransportOffer{
		{Kind: "tcp", Port: 7777},
		{Kind: "quic", Port: 7777},
		{Kind: "udp", Port: 7780},
	}
	c := &Core{Transport: netx.Auto}
	// quic already condemned, the way it is after two failed dials under Wine.
	c.mu.Lock()
	c.unusableTransports = map[string]bool{netx.QUIC.String(): true}
	c.mu.Unlock()

	var kind netx.Kind
	out := captureLog(t, func() { kind, _ = c.chooseTransport("relay.example:7777", offers) })

	if kind != netx.TCP {
		t.Fatalf("chose %v, want tcp", kind)
	}
	if !strings.Contains(out, "using tcp") {
		t.Fatalf("the tcp choice was not logged -- this is the silence the Proton log showed.\nlogged: %q", out)
	}
	if !strings.Contains(out, "relay.example:7777") {
		t.Fatalf("the tcp line does not say where it connected: %q", out)
	}
}

// The same must hold when tcp was ASKED for rather than fallen back to: the log names the
// transport in use either way, so reading it never requires knowing which case applied.
func TestExplicitTCPIsLogged(t *testing.T) {
	offers := []protocol.TransportOffer{{Kind: "tcp", Port: 7777}, {Kind: "quic", Port: 7777}}
	c := &Core{Transport: netx.TCP}

	var kind netx.Kind
	out := captureLog(t, func() { kind, _ = c.chooseTransport("relay.example:7777", offers) })

	if kind != netx.TCP {
		t.Fatalf("chose %v, want tcp", kind)
	}
	if !strings.Contains(out, "using tcp") {
		t.Fatalf("an explicit tcp choice was not logged: %q", out)
	}
}

// The quic line must not have regressed while adding the tcp one.
func TestChoosingQUICStillLogsQUIC(t *testing.T) {
	offers := []protocol.TransportOffer{{Kind: "tcp", Port: 7777}, {Kind: "quic", Port: 7777}}
	c := &Core{Transport: netx.Auto}

	var kind netx.Kind
	out := captureLog(t, func() { kind, _ = c.chooseTransport("relay.example:7777", offers) })

	if kind != netx.QUIC {
		t.Fatalf("chose %v, want quic", kind)
	}
	if !strings.Contains(out, "using quic") {
		t.Fatalf("the quic line was lost: %q", out)
	}
	if strings.Contains(out, "using tcp") {
		t.Fatalf("a quic choice also claimed tcp: %q", out)
	}
}
