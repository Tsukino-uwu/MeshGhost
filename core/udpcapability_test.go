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

// A MACHINE THAT CANNOT OPEN A UDP SOCKET MUST NOT BE OFFERED ONE, EVER.
//
// The Proton case: quic and plain udp both begin with net.ListenUDP, so neither can work,
// and dialling them to discover that costs two failed dials and seconds of connect delay on
// every launch -- relearned each time, because the core exits with the game.
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

// THE CASE THAT RULES OUT A CONFIG FLAG.
//
// A Linux player can have both: a native Linux client and a Proton one, reading the SAME
// config.json out of the same game folder. A setting in that file cannot distinguish them --
// it would pin the native client to tcp too, throwing away the quic it can perfectly well
// use. The probe asks about THIS PROCESS, so the native client keeps quic with no setting
// involved and nothing for a player to get wrong.
func TestANativeClientKeepsQUICWithTheSameConfig(t *testing.T) {
	// Same Transport setting as the Proton client above -- the only difference is the
	// machine, which is exactly the difference a config key cannot express.
	c := &Core{Transport: netx.Auto, udpProbe: func() bool { return true }}

	kind, addr := c.chooseTransport("relay.example:7777", fullOffers())
	if kind != netx.QUIC {
		t.Fatalf("a client whose udp works chose %v, want quic", kind)
	}
	if addr == "" {
		t.Fatal("quic was chosen with an empty address")
	}
}

// AN EXPLICIT PREFERENCE IS STILL NOT SILENTLY MOVED, matching what unusableTransports
// already does: somebody who wrote "quic" is told it is failing rather than downgraded
// behind their back. The clear repeated error IS the answer for them.
func TestExplicitQUICIsNotSkippedByTheProbe(t *testing.T) {
	c := &Core{Transport: netx.QUIC, udpProbe: func() bool { return false }}

	kind, _ := c.chooseTransport("relay.example:7777", fullOffers())
	if kind != netx.QUIC {
		t.Fatalf("an explicitly requested quic was downgraded to %v by the probe", kind)
	}
}

// The explanation is once per process, not once per connect attempt -- chooseTransport runs
// on every retry and the answer cannot change while the process lives.
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

// The probe must not fire at all when the relay offers nothing but tcp -- there is no
// downgrade to explain, and claiming one would be a false alarm in the log.
func TestNoUDPComplaintWhenTheRelayOffersOnlyTCP(t *testing.T) {
	c := &Core{Transport: netx.Auto, udpProbe: func() bool { return false }}
	offers := []protocol.TransportOffer{{Kind: "tcp", Port: 7777}}

	out := captureLog(t, func() { c.chooseTransport("relay.example:7777", offers) })

	if strings.Contains(out, "cannot open a udp socket") {
		t.Fatalf("explained a udp downgrade for a relay that never offered udp: %q", out)
	}
}
