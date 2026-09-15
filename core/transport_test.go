package core

import (
	"bufio"
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
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

	// And tcp wins even when udp is the ONLY thing advertised. tcp is always
	// reachable — the handshake that produced these offers just used it —
	// so reaching tcp in the preference order short-circuits. (Since
	// 2026-09-15 a release's AutoPreference has no udp entry at all, ADR
	// 0065; an old relay may still OFFER udp, which is what this row keeps
	// covering: the offer is ignored, not dialled.)
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
	kind, addr, _, err := c.resolveTransport("127.0.0.1:1", "g", "r", "n", "", "")
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
	if _, _, _, err := c.resolveTransport("127.0.0.1:1", "g", "r", "n", "", ""); err == nil {
		t.Fatal("an unreachable relay returned no error; the caller would dial again and fail twice")
	}
}

// ---------------------------------------------------------------- TLS

// discoveryRelay is a minimum relay for the discovery leg only: it accepts a
// TLS connection with the package's test identity, reads one hello, answers
// with the given transport offers, and hangs up. Enough to exercise
// resolveTransport, which is where both legs get their verifier.
func discoveryRelay(t *testing.T, offers []protocol.TransportOffer) string {
	t.Helper()
	ln := listenTLS(t)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
				br := bufio.NewReader(c)
				if _, err := br.ReadString(byte('\n')); err != nil {
					return
				}
				payload, err := json.Marshal(protocol.Transports{Offers: offers})
				if err != nil {
					return
				}
				env, err := json.Marshal(protocol.Envelope{
					Type:    protocol.TypeTransports,
					Payload: payload,
				})
				if err != nil {
					return
				}
				_, _ = c.Write(append(env, '\n'))
				// Give the client time to read before the deferred close.
				time.Sleep(200 * time.Millisecond)
			}(c)
		}
	}()
	return ln.Addr().String()
}

// plaintextRelay is a relay from before 2026-08-19: it reads a line and
// hangs up, never handshaking.
func plaintextRelay(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
				_, _ = bufio.NewReader(c).ReadString(byte('\n'))
			}(c)
		}
	}()
	return ln.Addr().String()
}

// TestBothLegsVerifyAgainstOneKnownRelaysEntry: the discovery leg records
// the relay under the CONFIGURED address, and the options handed to the
// session leg verify against that same entry -- whatever port the session
// leg dials. One relay, one entry, both legs.
func TestBothLegsVerifyAgainstOneKnownRelaysEntry(t *testing.T) {
	addr := discoveryRelay(t, offers("tcp", 7780))
	_, fp := testIdentity()

	c := &Core{Transport: netx.Auto}
	_, _, opts, err := c.resolveTransport(addr, "g", "r", "n", "", "")
	if err != nil {
		t.Fatalf("resolveTransport: %v", err)
	}
	if got, ok := c.KnownRelays.Lookup(addr); !ok || got != fp {
		t.Fatalf("after the discovery leg the store holds %q (present=%v) for %s; want the relay's %q", got, ok, addr, fp)
	}
	if opts.Verify == nil {
		t.Fatal("the session leg was handed no verifier")
	}
	if err := opts.Verify(testIdentityDER()); err != nil {
		t.Fatalf("the session leg's verifier refused the relay the discovery leg just trusted: %v", err)
	}
}

// TestAutoRefusesAPlaintextDiscoveryRelay: the discovery leg carries the room
// code, so it is the leg that must never go plaintext. A relay that cannot
// handshake is an error from resolveTransport, not a plaintext query.
func TestAutoRefusesAPlaintextDiscoveryRelay(t *testing.T) {
	addr := plaintextRelay(t)
	c := &Core{Transport: netx.Auto}
	_, _, _, err := c.resolveTransport(addr, "g", "r", "n", "secret", "")
	if err == nil {
		t.Fatal("an auto client queried a plaintext relay -- the room code just crossed in the clear")
	}
	offers, err := c.queryTransports(addr, "g", "r", "n", "secret", "", c.tlsOptions(addr))
	if err == nil || len(offers) > 0 {
		t.Fatal("queryTransports completed against a plaintext relay")
	}
}

// TestATCPPreferenceStillVerifies: the tcp short-circuit skips discovery
// entirely, so it is the one path that could hand the session a dial with
// no verifier.
func TestATCPPreferenceStillVerifies(t *testing.T) {
	c := &Core{Transport: netx.TCP}
	_, _, opts, err := c.resolveTransport("127.0.0.1:1", "g", "r", "n", "", "")
	if err != nil {
		t.Fatalf("resolveTransport: %v", err)
	}
	if opts.Verify == nil {
		t.Fatal("the tcp short-circuit handed the session leg no verifier")
	}
	if c.KnownRelays == nil || c.KnownRelays.Path() != "" {
		t.Fatalf("a Core without a store must get an in-memory one on first use; got %v", c.KnownRelays)
	}
}

// TestACoreWithoutAStoreNeverDialsUnverified: the in-memory fallback is a
// real store -- the first connection records, and a second relay at the
// same address with a different certificate is noticed (warned about, for
// now: the warning line is the store's, asserted in knownrelays_test.go).
func TestACoreWithoutAStoreNeverDialsUnverified(t *testing.T) {
	relayAddr := startRelay(t)
	c := New()
	c.RelayAddr = relayAddr
	c.Room = "room1"
	c.DisplayName = "alice"
	c.DialTimeout = testTimeout
	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("connect: %v", err)
	}
	_, fp := testIdentity()
	if got, ok := c.KnownRelays.Lookup(relayAddr); !ok || got != fp {
		t.Fatalf("after connecting, the in-memory store holds %q (present=%v); want %q", got, ok, fp)
	}
}
