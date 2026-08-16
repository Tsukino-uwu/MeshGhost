package core

import (
	"testing"

	"meshghost/internal/netx"
	"meshghost/internal/protocol"
)

// chooseTransport is where a relay's advertised offers become the actual
// dial target, and it is all branching: honour an explicit preference
// exactly, rank only under auto, fall back to tcp, and rebuild the address
// from the host the USER configured rather than anything the relay said.
// Its only other coverage is indirect (internal/e2e), which cannot reach
// most of these branches.

func offers(kv ...any) []protocol.TransportOffer {
	var out []protocol.TransportOffer
	for i := 0; i+1 < len(kv); i += 2 {
		out = append(out, protocol.TransportOffer{Kind: kv[i].(string), Port: kv[i+1].(int)})
	}
	return out
}

// TestExplicitPreferenceIsHonouredExactly: asking for udp gets udp, on the
// port the relay named — not the one in connect_to.
func TestExplicitPreferenceIsHonouredExactly(t *testing.T) {
	c := &Core{Transport: netx.UDP}
	kind, addr := c.chooseTransport("10.0.0.5:7777", offers("tcp", 7777, "udp", 7777, "quic", 7780))
	if kind != netx.UDP || addr != "10.0.0.5:7777" {
		t.Fatalf("got %v at %q, want udp at 10.0.0.5:7777", kind, addr)
	}

	c = &Core{Transport: netx.QUIC}
	kind, addr = c.chooseTransport("10.0.0.5:7777", offers("tcp", 7777, "udp", 7777, "quic", 7780))
	if kind != netx.QUIC || addr != "10.0.0.5:7780" {
		t.Fatalf("got %v at %q, want quic at 10.0.0.5:7780", kind, addr)
	}
}

// TestExplicitPreferenceNeverFallsSidewaysToUDP is the safety property. A
// client that asked for quic wants encryption; silently landing it on udp
// because both are "the fast one" would swap an encrypted session for one
// that CANNOT be encrypted. Falling back to tcp is right; falling sideways
// is not.
func TestExplicitPreferenceNeverFallsSidewaysToUDP(t *testing.T) {
	c := &Core{Transport: netx.QUIC}
	kind, addr := c.chooseTransport("10.0.0.5:7777", offers("tcp", 7777, "udp", 7777))
	if kind == netx.UDP {
		t.Fatal("a client that asked for quic was given udp — an unencryptable transport")
	}
	if kind != netx.TCP || addr != "10.0.0.5:7777" {
		t.Fatalf("got %v at %q, want tcp at the configured address", kind, addr)
	}
}

// TestAutoPrefersQUICAndAvoidsUDP pins the ranking end to end through the
// real chooser, not just the AutoPreference slice.
func TestAutoPrefersQUICAndAvoidsUDP(t *testing.T) {
	c := &Core{Transport: netx.Auto}

	kind, addr := c.chooseTransport("h:7777", offers("tcp", 7777, "udp", 7777, "quic", 7780))
	if kind != netx.QUIC || addr != "h:7780" {
		t.Fatalf("got %v at %q, want quic", kind, addr)
	}

	// tcp beats udp, because udp cannot be encrypted and nothing should
	// choose that on a user's behalf.
	if kind, _ := c.chooseTransport("h:7777", offers("tcp", 7777, "udp", 7777)); kind != netx.TCP {
		t.Fatalf("auto picked %v over tcp; udp must never be chosen automatically while another option exists", kind)
	}

	// And tcp wins even when udp is the ONLY thing advertised. tcp ranks
	// above udp and is always reachable — the handshake that produced these
	// offers just used it — so reaching tcp in the preference order
	// short-circuits and udp is never selected automatically at all.
	//
	// That makes AutoPreference's udp entry unreachable by construction,
	// which is the intended outcome rather than an oversight: udp cannot be
	// encrypted, so it stays available only to someone who names it.
	if kind, addr := c.chooseTransport("h:7777", offers("udp", 9999)); kind != netx.TCP || addr != "h:7777" {
		t.Fatalf("auto got %v at %q, want tcp — udp must never be selected automatically", kind, addr)
	}
}

// TestNoOffersOrUnparseableAddressStaysOnTCP covers the degrade paths: an
// older relay (no offers) and a malformed connect_to must both yield a
// working tcp attempt at the configured address, never an error and never a
// guess.
func TestNoOffersOrUnparseableAddressStaysOnTCP(t *testing.T) {
	c := &Core{Transport: netx.QUIC}

	if kind, addr := c.chooseTransport("h:7777", nil); kind != netx.TCP || addr != "h:7777" {
		t.Fatalf("no offers gave %v at %q, want tcp at the configured address", kind, addr)
	}
	if kind, addr := c.chooseTransport("not-an-address", offers("quic", 7780)); kind != netx.TCP || addr != "not-an-address" {
		t.Fatalf("unparseable address gave %v at %q, want it returned untouched", kind, addr)
	}
}

// TestNonsensePortsAreIgnored: the port comes from the network, so it is
// untrusted input. A relay claiming port 0 or 70000 must not produce a dial
// target built from it.
func TestNonsensePortsAreIgnored(t *testing.T) {
	c := &Core{Transport: netx.QUIC}
	for _, bad := range []int{0, -1, 65536, 999999} {
		kind, addr := c.chooseTransport("h:7777", offers("quic", bad))
		if kind != netx.TCP || addr != "h:7777" {
			t.Errorf("port %d gave %v at %q, want it ignored and tcp used", bad, kind, addr)
		}
	}
}

// TestTheHostAlwaysComesFromConfigNotTheRelay is what makes discovery work
// through NAT: a relay bound to 0.0.0.0 has no idea what address reaches
// it, so only the PORT is taken from the offer. If a host ever leaked in
// from the relay side, a port-forwarded session would dial something
// unreachable.
func TestTheHostAlwaysComesFromConfigNotTheRelay(t *testing.T) {
	c := &Core{Transport: netx.QUIC}
	_, addr := c.chooseTransport("203.0.113.9:7777", offers("quic", 7780))
	if addr != "203.0.113.9:7780" {
		t.Fatalf("dial target %q, want the configured host with the offered port", addr)
	}
}

// TestTCPPreferenceNeedsNoDiscovery: with tcp there is nothing to upgrade
// to, so resolveTransport must short-circuit without dialing anything. A
// relay address that does not exist proves it never tried.
func TestTCPPreferenceNeedsNoDiscovery(t *testing.T) {
	c := &Core{Transport: netx.TCP}
	kind, addr, err := c.resolveTransport("127.0.0.1:1", "g", "r", "n", "", "")
	if err != nil {
		t.Fatalf("tcp preference returned an error (%v); it must not dial at all", err)
	}
	if kind != netx.TCP || addr != "127.0.0.1:1" {
		t.Fatalf("got %v at %q, want tcp at the configured address", kind, addr)
	}
}

// TestUnreachableRelayPropagatesItsError: when the tcp handshake itself
// fails, that IS the connection failure, so it must reach the caller rather
// than being swallowed into a doomed second attempt.
func TestUnreachableRelayPropagatesItsError(t *testing.T) {
	c := &Core{Transport: netx.QUIC}
	if _, _, err := c.resolveTransport("127.0.0.1:1", "g", "r", "n", "", ""); err == nil {
		t.Fatal("an unreachable relay returned no error; the caller would dial again and fail twice")
	}
}
