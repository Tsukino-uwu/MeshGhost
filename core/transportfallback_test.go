package core

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
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
