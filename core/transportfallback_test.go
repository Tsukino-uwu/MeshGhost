package core

import (
	"net"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// A transport this machine cannot dial must not be chosen again in AUTOMATIC mode.
//
// Found in a real session, not by reasoning: a Windows client running under Wine picked quic --
// the top automatic preference -- and quic-go's UDP setup returned WSAEOPNOTSUPP, surfaced as
// "winapi error #10045", because Wine does not implement the socket option it needs. Selection was
// stateless, so every retry re-picked quic and failed identically, forever, while tcp sat there
// working. The user's own workaround was to force tcp by hand.
//
// The relay is not at fault and neither is the offer: the transport is genuinely offered and
// genuinely undiallable HERE. That is a property of the machine, so the client is the only side
// that can learn it.
func TestAutoModeStopsChoosingATransportThatCannotBeDialled(t *testing.T) {
	offers := []protocol.TransportOffer{
		{Kind: "tcp", Port: 7777},
		{Kind: "udp", Port: 7775},
		{Kind: "quic", Port: 7776},
	}

	c := &Core{Transport: netx.Auto}

	// Before any failure, automatic selection prefers quic -- unchanged behaviour.
	kind, _ := c.chooseTransport("127.0.0.1:7777", offers)
	if kind != netx.QUIC {
		t.Fatalf("automatic mode first picked %v, want quic (the top preference)", kind)
	}

	// The dial failed, the way it does under Wine.
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

// Everything unusable must still leave a working session, because the handshake already proved
// tcp reaches this relay. Falling back to nothing would turn a degraded session into no session.
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

// AN EXPLICIT PREFERENCE IS NOT SILENTLY MOVED, and that asymmetry is deliberate.
//
// chooseTransport already refuses to let an explicit quic land on plain udp, because it would swap
// an encrypted session for one that cannot be encrypted. The same reasoning applies here: someone
// who asked for quic and cannot have it should keep seeing the failure rather than be quietly
// downgraded. Only netx.Auto -- which is a request to pick something that works -- may skip.
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

// relayAdvertisingADeadQUICPort is the RESTARTING-RELAY shape, and the only shape that can
// reach the dial-failure path at all: a relay whose tcp listener is up and answering the
// handshake, while the quic port it advertises accepts nothing.
//
// A relay that is entirely down cannot produce this -- resolveTransport's tcp handshake fails
// first and returns before any transport is dialled -- which is what bounds this whole risk.
func relayAdvertisingADeadQUICPort(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	// Set BEFORE Serve: the offers are read by the handshake goroutine.
	s.Offers = []protocol.TransportOffer{
		{Kind: "tcp", Port: ln.Addr().(*net.TCPAddr).Port},
		{Kind: "quic", Port: deadPort(t)},
	}
	go s.Serve(ln)
	return ln.Addr().String()
}

// ONE FAILED DIAL MUST NOT CONDEMN A TRANSPORT FOR THE WHOLE SESSION.
//
// This is the regression test for a defect introduced by the fallback itself, on the exact path
// a restarting relay takes. A relay coming back up has its tcp listener accepting before its quic
// listener does; a client reconnecting inside that window succeeds at the handshake and then fails
// the quic dial. Condemning on that single failure pins the rest of the session to tcp -- silently,
// with a working session and nothing visible on screen, so nobody would ever report it.
//
// Without the consecutive-failure requirement this test fails on the FIRST attempt.
func TestOneFailedDialDoesNotCondemnATransport(t *testing.T) {
	addr := relayAdvertisingADeadQUICPort(t)

	c := New()
	c.RelayAddr = addr
	c.Transport = netx.Auto
	c.DialTimeout = testTimeout

	// First attempt: quic is chosen, and cannot be dialled.
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

// ...but a transport that keeps failing IS given up on, and the session still works.
//
// The pair matters: the test above alone could be satisfied by never condemning anything, which
// would restore the Wine loop this whole mechanism exists to break.
func TestARepeatedlyFailingTransportIsGivenUpOnAndTheSessionSurvivesOnTCP(t *testing.T) {
	addr := relayAdvertisingADeadQUICPort(t)

	c := New()
	c.RelayAddr = addr
	c.Transport = netx.Auto
	c.DialTimeout = testTimeout

	// Attempt until quic is condemned, bounded so a failure to condemn shows up as this
	// assertion rather than as a hang.
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
