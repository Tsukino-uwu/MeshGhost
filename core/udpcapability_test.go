package core

import (
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func fullOffers() []protocol.TransportOffer {
	return []protocol.TransportOffer{
		{Kind: "tcp", Port: 7777},
		{Kind: "quic", Port: 7777},
		{Kind: "udp", Port: 7780},
	}
}

// Under Proton quic and udp both fail at net.ListenUDP, and dialling them to find out costs two failed dials on every
// launch, since the core exits with the game.
func TestUDPIncapableMachineSkipsQUICAndUDPWithoutDialling(t *testing.T) {
	c := &Core{Transport: netx.Auto, udpProbe: func() bool { return false }}

	var kind netx.Kind
	out := captureLog(t, func() { kind, _ = c.chooseTransport("relay.example:7777", fullOffers()) })

	if kind != netx.TCP {
		t.Fatalf("a machine with no udp chose %v, want tcp", kind)
	}
	if !strings.Contains(out, "cannot open a udp socket") {
		t.Fatalf("the downgrade was not explained: %q", out)
	}
	if !strings.Contains(out, "using tcp") {
		t.Fatalf("the transport in use was not named: %q", out)
	}
}

// A native Linux client and a Proton one can read the same config.json, so no config flag can tell them apart; the
// probe asks about this process.
func TestANativeClientKeepsQUICWithTheSameConfig(t *testing.T) {
	c := &Core{Transport: netx.Auto, udpProbe: func() bool { return true }}

	kind, addr := c.chooseTransport("relay.example:7777", fullOffers())
	if kind != netx.QUIC {
		t.Fatalf("a client whose udp works chose %v, want quic", kind)
	}
	if addr == "" {
		t.Fatal("quic was chosen with an empty address")
	}
}

// An explicit preference is never silently moved, as with unusableTransports: whoever wrote "quic" is told it fails.
func TestExplicitQUICIsNotSkippedByTheProbe(t *testing.T) {
	c := &Core{Transport: netx.QUIC, udpProbe: func() bool { return false }}

	kind, _ := c.chooseTransport("relay.example:7777", fullOffers())
	if kind != netx.QUIC {
		t.Fatalf("an explicitly requested quic was downgraded to %v by the probe", kind)
	}
}

// chooseTransport runs on every retry, and the answer cannot change while the process lives.
func TestTheUDPDowngradeIsExplainedOnce(t *testing.T) {
	c := &Core{Transport: netx.Auto, udpProbe: func() bool { return false }}

	out := captureLog(t, func() {
		for range 5 {
			c.chooseTransport("relay.example:7777", fullOffers())
		}
	})

	if n := strings.Count(out, "cannot open a udp socket"); n != 1 {
		t.Fatalf("the downgrade was explained %d times across 5 attempts, want exactly 1:\n%s", n, out)
	}
}

func TestNoUDPComplaintWhenTheRelayOffersOnlyTCP(t *testing.T) {
	c := &Core{Transport: netx.Auto, udpProbe: func() bool { return false }}
	offers := []protocol.TransportOffer{{Kind: "tcp", Port: 7777}}

	out := captureLog(t, func() { c.chooseTransport("relay.example:7777", offers) })

	if strings.Contains(out, "cannot open a udp socket") {
		t.Fatalf("explained a udp downgrade for a relay that never offered udp: %q", out)
	}
}
