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

// TestFallingBackToTCPIsLogged: a session that ends up on tcp says so, or the transport in use can be learned only
// from a later disconnect message.
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
