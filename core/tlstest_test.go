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

// Every relay a core test dials serves TLS, because every relay does since
// 2026-09-15 (ADR 0066) and a core never dials plaintext. These helpers are
// the one place that identity lives for the package: one certificate for
// every test relay, generated once, so a test that restarts a relay on the
// same address sees the same identity a real restart would.

var testIdentity = sync.OnceValues(func() (*tls.Config, string) {
	cfg, fp, err := tlsx.ServerConfig(netx.TLSALPN)
	if err != nil {
		panic("test identity: " + err.Error())
	}
	return cfg, fp
})

// testIdentityDER is the leaf certificate every test relay presents, for a
// test that wants to drive a Verifier by hand.
func testIdentityDER() []byte {
	cfg, _ := testIdentity()
	return cfg.Certificates[0].Certificate[0]
}

// bindProofToTestIdentity does what cmd/meshghost-relay does: the room-code
// proof (ADR 0067) is registered under the fingerprint of the certificate
// the relay serves, so a core -- which names the fingerprint it verified --
// can prove a code to a test relay at all. Left unset, the relay registers
// under pake.UnboundIdentity and every coded join fails on the client, which
// is the binding working, not a test relay.
func bindProofToTestIdentity(s *relay.Server) {
	if s.PakeIdentity == "" {
		_, s.PakeIdentity = testIdentity()
	}
}

// serveTLS wraps a raw listener the way the relay's tcp listener is wrapped:
// every accepted connection is a completed TLS handshake, and a plaintext
// one is refused. The accept loop a test runs on top sees only the former.
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

// listenTLSOn is listenTLS on a specific address: a relay coming back on the
// port a test reserved.
func listenTLSOn(t testing.TB, addr string) net.Listener {
	t.Helper()
	raw, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("listen on %s: %v", addr, err)
	}
	return serveTLS(t, raw)
}

// listenQUICWithTestIdentity serves quic with the same certificate the tcp
// test relays present, as the real relay does.
func listenQUICWithTestIdentity(t testing.TB, addr string) net.Listener {
	t.Helper()
	cfg, _ := testIdentity()
	ln, err := netx.ListenWithTLS(netx.QUIC, addr, netx.TLSOptions{Server: cfg, Logf: func(string, ...any) {}})
	if err != nil {
		t.Fatalf("listen quic on %s: %v", addr, err)
	}
	return ln
}

// dialRelayTLS is a hand-driven client's connection to a test relay: TLS,
// accepting the relay's certificate. What a test that speaks the wire by
// hand (rejectreason_wirefreeze_test.go) uses in place of a raw dial.
func dialRelayTLS(t testing.TB, addr string) net.Conn {
	t.Helper()
	conn, err := netx.DialWithTLS(netx.TCP, addr, testTimeout, netx.TLSOptions{Verify: tlsx.TrustAnyCertificate})
	if err != nil {
		t.Fatalf("dial relay %s: %v", addr, err)
	}
	return conn
}
