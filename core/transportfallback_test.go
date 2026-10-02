package core

import (
	"net"
	"strconv"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// TestAutoModeStopsChoosingATransportThatCannotBeDialled: a transport offered by the relay but undiallable on this
// machine (quic under Wine) is a property of the machine, so only the client can learn to skip it in auto mode.
func TestAutoModeStopsChoosingATransportThatCannotBeDialled(t *testing.T) {
	offers := []protocol.TransportOffer{
		{Kind: "tcp", Port: 7777},
		{Kind: "udp", Port: 7775},
		{Kind: "quic", Port: 7776},
	}

	c := &Core{Transport: netx.Auto}

	kind, _ := c.chooseTransport("127.0.0.1:7777", offers)
	if kind != netx.QUIC {
		t.Fatalf("automatic mode first picked %v, want quic (the top preference)", kind)
	}

	c.mu.Lock()
	c.unusableTransports = map[string]bool{netx.QUIC.String(): true}
	c.mu.Unlock()

	kind, addr := c.chooseTransport("127.0.0.1:7777", offers)
	if kind == netx.QUIC {
		t.Fatal("automatic mode chose quic again after it failed to dial -- this is the loop the " +
			"Wine session was stuck in, re-picking a transport that cannot work on this machine")
	}
	if kind != netx.UDP && kind != netx.TCP {
		t.Fatalf("fell back to %v, want the next offered preference (udp) or tcp", kind)
	}
	if addr == "" {
		t.Fatal("fell back to an empty address")
	}
}

// TestAutoModeFallsAllTheWayToTCP: with everything else unusable the session stays on tcp, which the handshake
// already proved reaches this relay.
func TestAutoModeFallsAllTheWayToTCP(t *testing.T) {
	offers := []protocol.TransportOffer{
		{Kind: "tcp", Port: 7777},
		{Kind: "udp", Port: 7775},
		{Kind: "quic", Port: 7776},
	}
	c := &Core{Transport: netx.Auto}
	c.mu.Lock()
	c.unusableTransports = map[string]bool{netx.QUIC.String(): true, netx.UDP.String(): true}
	c.mu.Unlock()

	kind, addr := c.chooseTransport("127.0.0.1:7777", offers)
	if kind != netx.TCP {
		t.Fatalf("with quic and udp both unusable the choice was %v, want tcp", kind)
	}
	if addr != "127.0.0.1:7777" {
		t.Fatalf("tcp fallback used %q, want the original handshake address", addr)
	}
}

// TestAnExplicitPreferenceIsNeverSkipped: a player who asked for quic and cannot have it keeps seeing the failure
// rather than being quietly downgraded; only netx.Auto may skip.
func TestAnExplicitPreferenceIsNeverSkipped(t *testing.T) {
	offers := []protocol.TransportOffer{
		{Kind: "tcp", Port: 7777},
		{Kind: "quic", Port: 7776},
	}
	c := &Core{Transport: netx.QUIC}
	c.mu.Lock()
	c.unusableTransports = map[string]bool{netx.QUIC.String(): true}
	c.mu.Unlock()

	kind, _ := c.chooseTransport("127.0.0.1:7777", offers)
	if kind != netx.QUIC {
		t.Fatalf("an explicitly requested quic was silently changed to %v; only automatic mode "+
			"may skip a transport, so the user keeps being told what is wrong", kind)
	}
}

// deadPort returns a port nothing is listening on, by binding one and letting it go.
func deadPort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	return port
}

// relayAdvertisingADeadQUICPort is a restarting relay: its tcp listener answers the handshake while the quic port it
// advertises accepts nothing. A relay entirely down never reaches the dial, since the tcp handshake fails first.
func relayAdvertisingADeadQUICPort(t *testing.T) string {
	t.Helper()
	ln := listenTLS(t)

	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	// Set before Serve: the handshake goroutine reads the offers.
	s.Offers = []protocol.TransportOffer{
		{Kind: "tcp", Port: ln.Addr().(*net.TCPAddr).Port},
		{Kind: "quic", Port: deadPort(t)},
	}
	go s.Serve(ln)
	return ln.Addr().String()
}

// TestOneFailedDialDoesNotCondemnATransport: a restarting relay accepts tcp before quic, so one failed quic dial would
// otherwise pin the session to tcp, silently.
func TestOneFailedDialDoesNotCondemnATransport(t *testing.T) {
	addr := relayAdvertisingADeadQUICPort(t)

	c := New()
	c.RelayAddr = addr
	c.Transport = netx.Auto
	c.DialTimeout = testTimeout

	if err := c.ConnectRelay("faketest"); err == nil {
		t.Fatal("connecting over a dead quic port succeeded, so this test proves nothing")
	}

	c.mu.Lock()
	condemned := c.unusableTransports[netx.QUIC.String()]
	failures := c.transportDialFailures[netx.QUIC.String()]
	c.mu.Unlock()

	if failures != 1 {
		t.Fatalf("recorded %d quic failures after one attempt, want 1", failures)
	}
	if condemned {
		t.Fatal("quic was given up on after ONE failed dial -- a relay that is merely restarting " +
			"fails one dial like this, and the session would be pinned to tcp until the game is " +
			"restarted, silently and with nothing on screen to report")
	}
}

// TestARepeatedlyFailingTransportIsGivenUpOnAndTheSessionSurvivesOnTCP is the converse of the test above, which
// alone a core that never condemns anything would pass.
func TestARepeatedlyFailingTransportIsGivenUpOnAndTheSessionSurvivesOnTCP(t *testing.T) {
	addr := relayAdvertisingADeadQUICPort(t)

	c := New()
	c.RelayAddr = addr
	c.Transport = netx.Auto
	c.DialTimeout = testTimeout

	// Bounded, so a failure to condemn shows as this assertion rather than a hang.
	var connected bool
	for attempt := 1; attempt <= transportDialFailuresBeforeGivingUp+2; attempt++ {
		if err := c.ConnectRelay("faketest"); err == nil {
			connected = true
			break
		}
	}
	if !connected {
		t.Fatalf("never established a session: quic kept being chosen even after "+
			"%d consecutive failures, which is the Wine loop", transportDialFailuresBeforeGivingUp+2)
	}

	c.mu.Lock()
	condemned := c.unusableTransports[netx.QUIC.String()]
	c.mu.Unlock()
	if !condemned {
		t.Fatal("a session was established without quic ever being recorded as unusable")
	}
}

// TestASuccessfulDialResetsTheConsecutiveFailureCount: two failures in a row must not mean two failures ever, or a
// relay that restarts twice in a long session condemns quic for the rest of it. The quic listener serves the same
// relay and goes down and comes back.
func TestASuccessfulDialResetsTheConsecutiveFailureCount(t *testing.T) {
	tcpLn := listenTLS(t)

	quicPort := deadPort(t)
	quicAddr := net.JoinHostPort("127.0.0.1", strconv.Itoa(quicPort))

	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	s.Offers = []protocol.TransportOffer{
		{Kind: "tcp", Port: tcpLn.Addr().(*net.TCPAddr).Port},
		{Kind: "quic", Port: quicPort},
	}
	go s.Serve(tcpLn)

	c := New()
	c.RelayAddr = tcpLn.Addr().String()
	c.Transport = netx.Auto
	c.DialTimeout = testTimeout

	failures := func() (int, bool) {
		c.mu.Lock()
		defer c.mu.Unlock()
		return c.transportDialFailures[netx.QUIC.String()], c.unusableTransports[netx.QUIC.String()]
	}

	// The quic listener is not up yet.
	if err := c.ConnectRelay("faketest"); err == nil {
		t.Fatal("connecting to an unserved quic port succeeded, so this test proves nothing")
	}
	if n, condemned := failures(); n != 1 || condemned {
		t.Fatalf("after one failed quic dial: %d failures, condemned=%v; want 1, false", n, condemned)
	}

	// The same identity as the tcp leg, as a real relay serves, so the known-relays entry matches on quic too.
	quicLn := listenQUICWithTestIdentity(t, quicAddr)
	go s.Serve(quicLn)
	if err := c.ConnectRelay("faketest"); err != nil {
		t.Fatalf("connecting over a served quic port failed: %v", err)
	}
	if n, _ := failures(); n != 0 {
		t.Fatalf("a successful quic dial left %d failures recorded, want the run cleared", n)
	}

	// The second failure overall and the first in a row: a transport that just worked is one this machine can do.
	quicLn.Close()
	if err := c.ConnectRelay("faketest"); err == nil {
		t.Fatal("connecting after the quic listener closed succeeded, so this test proves nothing")
	}
	if n, condemned := failures(); n != 1 || condemned {
		t.Fatalf("after a failure, a success and a failure: %d failures, condemned=%v; want 1, "+
			"false -- a cumulative counter condemns quic here, which is the defect", n, condemned)
	}
}
