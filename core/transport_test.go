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

// chooseTransport is all branching: an explicit preference exactly, ranking only under auto, a tcp fallback, and the
// host always from config. internal/e2e, its only other coverage, reaches few of these branches.

func offers(kv ...any) []protocol.TransportOffer {
	var out []protocol.TransportOffer
	for i := 0; i+1 < len(kv); i += 2 {
		out = append(out, protocol.TransportOffer{Kind: kv[i].(string), Port: kv[i+1].(int)})
	}
	return out
}

// TestExplicitPreferenceIsHonouredExactly: asking for udp gets udp, on the port the relay named, not connect_to's.
func TestExplicitPreferenceIsHonouredExactly(t *testing.T) {
	c := &Core{Transport: netx.UDP}
	kind, addr := c.chooseTransport("192.0.2.5:7777", offers("tcp", 7777, "udp", 7777, "quic", 7780))
	if kind != netx.UDP || addr != "192.0.2.5:7777" {
		t.Fatalf("got %v at %q, want udp at 192.0.2.5:7777", kind, addr)
	}

	c = &Core{Transport: netx.QUIC}
	kind, addr = c.chooseTransport("192.0.2.5:7777", offers("tcp", 7777, "udp", 7777, "quic", 7780))
	if kind != netx.QUIC || addr != "192.0.2.5:7780" {
		t.Fatalf("got %v at %q, want quic at 192.0.2.5:7780", kind, addr)
	}
}

// TestExplicitPreferenceNeverFallsSidewaysToUDP: a client that asked for quic wants encryption, so it falls back to
// tcp, never sideways to udp, which cannot be encrypted.
func TestExplicitPreferenceNeverFallsSidewaysToUDP(t *testing.T) {
	c := &Core{Transport: netx.QUIC}
	kind, addr := c.chooseTransport("192.0.2.5:7777", offers("tcp", 7777, "udp", 7777))
	if kind == netx.UDP {
		t.Fatal("a client that asked for quic was given udp — an unencryptable transport")
	}
	if kind != netx.TCP || addr != "192.0.2.5:7777" {
		t.Fatalf("got %v at %q, want tcp at the configured address", kind, addr)
	}
}

// TestAutoPrefersQUICAndAvoidsUDP pins the ranking through the real chooser, not just the AutoPreference slice.
func TestAutoPrefersQUICAndAvoidsUDP(t *testing.T) {
	c := &Core{Transport: netx.Auto}

	kind, addr := c.chooseTransport("h:7777", offers("tcp", 7777, "udp", 7777, "quic", 7780))
	if kind != netx.QUIC || addr != "h:7780" {
		t.Fatalf("got %v at %q, want quic", kind, addr)
	}

	// udp cannot be encrypted, so nothing picks it on a player's behalf.
	if kind, _ := c.chooseTransport("h:7777", offers("tcp", 7777, "udp", 7777)); kind != netx.TCP {
		t.Fatalf("auto picked %v over tcp; udp must never be chosen automatically while another option exists", kind)
	}

	// Even when udp is the only offer: the handshake just used tcp, and an old relay may still offer udp.
	if kind, addr := c.chooseTransport("h:7777", offers("udp", 9999)); kind != netx.TCP || addr != "h:7777" {
		t.Fatalf("auto got %v at %q, want tcp — udp must never be selected automatically", kind, addr)
	}
}

// TestNoOffersOrUnparseableAddressStaysOnTCP: an older relay (no offers) and a malformed connect_to both yield a tcp
// attempt at the configured address, never an error or a guess.
func TestNoOffersOrUnparseableAddressStaysOnTCP(t *testing.T) {
	c := &Core{Transport: netx.QUIC}

	if kind, addr := c.chooseTransport("h:7777", nil); kind != netx.TCP || addr != "h:7777" {
		t.Fatalf("no offers gave %v at %q, want tcp at the configured address", kind, addr)
	}
	if kind, addr := c.chooseTransport("not-an-address", offers("quic", 7780)); kind != netx.TCP || addr != "not-an-address" {
		t.Fatalf("unparseable address gave %v at %q, want it returned untouched", kind, addr)
	}
}

// TestNonsensePortsAreIgnored: the offered port is untrusted network input, so an out-of-range one is never dialled.
func TestNonsensePortsAreIgnored(t *testing.T) {
	c := &Core{Transport: netx.QUIC}
	for _, bad := range []int{0, -1, 65536, 999999} {
		kind, addr := c.chooseTransport("h:7777", offers("quic", bad))
		if kind != netx.TCP || addr != "h:7777" {
			t.Errorf("port %d gave %v at %q, want it ignored and tcp used", bad, kind, addr)
		}
	}
}

// TestTheHostAlwaysComesFromConfigNotTheRelay: a relay bound to 0.0.0.0 cannot know the address that reaches it
// through NAT, so only the port is taken from the offer.
func TestTheHostAlwaysComesFromConfigNotTheRelay(t *testing.T) {
	c := &Core{Transport: netx.QUIC}
	_, addr := c.chooseTransport("203.0.113.9:7777", offers("quic", 7780))
	if addr != "203.0.113.9:7780" {
		t.Fatalf("dial target %q, want the configured host with the offered port", addr)
	}
}

// TestTCPPreferenceNeedsNoDiscovery: with tcp there is nothing to upgrade to, so resolveTransport dials nothing; a
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

// TestUnreachableRelayPropagatesItsError: a failed tcp handshake is the connection failure, so it reaches the caller
// rather than a doomed second attempt.
func TestUnreachableRelayPropagatesItsError(t *testing.T) {
	c := &Core{Transport: netx.QUIC}
	if _, _, _, err := c.resolveTransport("127.0.0.1:1", "g", "r", "n", "", ""); err == nil {
		t.Fatal("an unreachable relay returned no error; the caller would dial again and fail twice")
	}
}

// discoveryRelay is a minimal relay for the discovery leg: over TLS with the package's test identity, it reads one
// hello, answers with the given offers, and hangs up.
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
				// Time for the client to read before the deferred close.
				time.Sleep(200 * time.Millisecond)
			}(c)
		}
	}()
	return ln.Addr().String()
}

// plaintextRelay is a relay without TLS: it reads a line and hangs up, never handshaking.
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

// TestBothLegsVerifyAgainstOneKnownRelaysEntry: the discovery leg records the relay under the configured address,
// and the session leg verifies against that same entry whatever port it dials.
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

// TestAutoRefusesAPlaintextDiscoveryRelay: the discovery leg carries the room code, so a relay that cannot handshake
// is an error, never a plaintext query.
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

// TestATCPPreferenceStillVerifies: the tcp short-circuit skips discovery, so it is the one path that could hand the
// session a dial with no verifier.
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

// TestACoreWithoutAStoreNeverDialsUnverified: the in-memory fallback is a real store, so the first connection is
// recorded.
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
