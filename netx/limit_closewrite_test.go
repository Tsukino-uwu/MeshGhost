package netx

import (
	"io"
	"net"
	"testing"
	"time"
)

// A limited connection must still be able to HALF-close.
//
// transport.CloseGracefully asserts for CloseWrite and falls back to a hard
// Close when the assertion fails. limitedConn embeds net.Conn as an interface,
// so before 2026-09-07 that assertion failed for every connection the relay
// accepted -- the limiter is applied unconditionally -- and every reject the
// relay wrote (wrong room code, version mismatch, rate limited) was lost to a
// TCP reset behind the unread data instead of reaching the client. The client
// then saw ECONNRESET, classified a PERMANENT refusal as a transport error,
// and retried it forever.
//
// This is the third connection wrapper to lose a method this way
// (WriteUnreliable 2026-09-02, then this one), which is why the test asserts
// the delivery, not just the method's presence.
func TestLimitListenerKeepsTheGracefulHalfClose(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	limited := LimitListener(ln, 4, nil)
	defer limited.Close()

	client, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()

	server, err := limited.Accept()
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	defer server.Close()

	cw, ok := server.(interface{ CloseWrite() error })
	if !ok {
		t.Fatal("a limited connection no longer exposes CloseWrite: " +
			"transport.CloseGracefully will fall back to a hard Close, and every " +
			"reject reason the relay writes is lost to the reset")
	}

	// The last line before the graceful close has to arrive, which is the whole
	// point: a reject is written and THEN the write side is closed.
	if _, err := server.Write([]byte("reject\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := cw.CloseWrite(); err != nil {
		t.Fatalf("CloseWrite: %v", err)
	}

	_ = client.SetReadDeadline(time.Now().Add(5 * time.Second))
	got, err := io.ReadAll(client)
	if err != nil {
		t.Fatalf("read after the peer's half-close: %v", err)
	}
	if string(got) != "reject\n" {
		t.Fatalf("the client read %q, want the reject line followed by a clean EOF", got)
	}
}

// The limiter must not invent a transport label for a connection that has none,
// and must not hide one that does. relay's transportName asserts for this
// method and defaults to "tcp", so a hidden method silently logged every udp
// and quic client as "tcp" in the per-client line a remote tester sends back.
func TestLimitListenerReportsTheUnderlyingTransportName(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	limited := LimitListener(ln, 4, nil)
	defer limited.Close()

	client, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()

	server, err := limited.Accept()
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	defer server.Close()

	tn, ok := server.(interface{ TransportName() string })
	if !ok {
		t.Fatal("a limited connection no longer exposes TransportName")
	}
	if got := tn.TransportName(); got != "tcp" {
		t.Fatalf("TransportName() = %q over a plain TCP conn, want %q", got, "tcp")
	}
}
