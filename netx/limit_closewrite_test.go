package netx

import (
	"io"
	"net"
	"testing"
	"time"
)

// TestLimitListenerKeepsTheGracefulHalfClose: without it transport.CloseGracefully falls back to a hard Close and the
// relay's reject is lost to a reset behind the unread data. It asserts the delivery, not just the method's presence.
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

// TestLimitListenerReportsTheUnderlyingTransportName: the limiter must not invent a label for a connection that has
// none, nor hide one that does: relay's transportName defaults to "tcp" when the method is hidden.
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
