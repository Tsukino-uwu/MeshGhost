package core

import (
	"crypto/tls"
	"net"
	"sync"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// Every relay a core test dials serves TLS, because a core never dials plaintext. One certificate for every test
// relay, generated once, so a relay restarted on the same address keeps its identity as a real restart would.

var testIdentity = sync.OnceValues(func() (*tls.Config, string) {
	cfg, fp, err := tlsx.ServerConfig(netx.TLSALPN)
	if err != nil {
		panic("test identity: " + err.Error())
	}
	return cfg, fp
})

// testIdentityDER is the leaf certificate every test relay presents, for a test that drives a Verifier by hand.
func testIdentityDER() []byte {
	cfg, _ := testIdentity()
	return cfg.Certificates[0].Certificate[0]
}

// bindProofToTestIdentity does what cmd/meshghost-relay does: it registers the room-code proof under the served
// certificate's fingerprint, the one a core names. Left unset, every coded join fails on the client, by design.
func bindProofToTestIdentity(s *relay.Server) {
	if s.PakeIdentity == "" {
		_, s.PakeIdentity = testIdentity()
	}
}

// serveTLS wraps a raw listener the way the relay's tcp listener is wrapped: every accepted connection is a completed
// TLS handshake, and a plaintext one is refused.
func serveTLS(t testing.TB, ln net.Listener) net.Listener {
	t.Helper()
	cfg, _ := testIdentity()
	wrapped, err := tlsx.NewListener(ln, tlsx.ListenConfig{TLS: cfg, Logf: func(string, ...any) {}})
	if err != nil {
		t.Fatalf("serveTLS: %v", err)
	}
	return wrapped
}

// listenTLS is net.Listen on loopback plus serveTLS, closed at cleanup.
func listenTLS(t testing.TB) net.Listener {
	t.Helper()
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ln := serveTLS(t, raw)
	t.Cleanup(func() { ln.Close() })
	return ln
}

// listenTLSOn is listenTLS on a specific address: a relay coming back on the port a test reserved.
func listenTLSOn(t testing.TB, addr string) net.Listener {
	t.Helper()
	raw, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("listen on %s: %v", addr, err)
	}
	return serveTLS(t, raw)
}

// listenQUICWithTestIdentity serves quic with the same certificate the tcp test relays present, as the real relay does.
func listenQUICWithTestIdentity(t testing.TB, addr string) net.Listener {
	t.Helper()
	cfg, _ := testIdentity()
	ln, err := netx.ListenWithTLS(netx.QUIC, addr, netx.TLSOptions{Server: cfg, Logf: func(string, ...any) {}})
	if err != nil {
		t.Fatalf("listen quic on %s: %v", addr, err)
	}
	return ln
}

// dialRelayTLS is a hand-driven client's connection to a test relay: TLS, accepting the relay's certificate, for a
// test that speaks the wire by hand.
func dialRelayTLS(t testing.TB, addr string) net.Conn {
	t.Helper()
	conn, err := netx.DialWithTLS(netx.TCP, addr, testTimeout, netx.TLSOptions{Verify: tlsx.TrustAnyCertificate})
	if err != nil {
		t.Fatalf("dial relay %s: %v", addr, err)
	}
	return conn
}
