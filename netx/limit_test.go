package netx

import (
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// TestLimitListenerClosesConnectionsPastTheCap: the cap counts connections
// from Accept until Close, the one past it is closed at once (its far end
// reads EOF promptly, rather than sitting until a timeout), and closing an
// accepted connection frees its slot.
func TestLimitListenerClosesConnectionsPastTheCap(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	// Written from the accept goroutine, read here: atomic, or the race
	// detector (CI, first push) rightly objects.
	var logged atomic.Int32
	ln := LimitListener(raw, 2, func(string, ...any) { logged.Add(1) }).(*limitListener)
	defer ln.Close()

	accepted := make(chan net.Conn, 8)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			accepted <- c
		}
	}()

	dial := func() net.Conn {
		t.Helper()
		c, err := net.Dial("tcp", raw.Addr().String())
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		t.Cleanup(func() { c.Close() })
		return c
	}
	waitAccepted := func() net.Conn {
		t.Helper()
		select {
		case c := <-accepted:
			return c
		case <-time.After(2 * time.Second):
			t.Fatal("connection under the cap was not accepted")
			return nil
		}
	}

	dial()
	first := waitAccepted()
	dial()
	waitAccepted()
	if got := ln.Open(); got != 2 {
		t.Fatalf("open = %d, want 2", got)
	}

	// Third: refused. Its far end must see EOF quickly.
	third := dial()
	_ = third.SetReadDeadline(time.Now().Add(2 * time.Second))
	if n, err := third.Read(make([]byte, 1)); err == nil {
		t.Fatalf("connection past the cap was not closed (read %d bytes)", n)
	}
	select {
	case <-accepted:
		t.Fatal("connection past the cap was handed to Accept")
	case <-time.After(100 * time.Millisecond):
	}
	if n := logged.Load(); n != 1 {
		t.Fatalf("refusal logged %d times, want 1", n)
	}

	// Free one slot; the next dial is accepted again.
	_ = first.Close()
	dial()
	waitAccepted()
	if got := ln.Open(); got != 2 {
		t.Fatalf("open after release = %d, want 2", got)
	}
}

// lossyConn is a net.Conn that also offers the state plane's unreliable
// write, the way quicconn.Conn and udpconn.Conn do.
type lossyConn struct {
	net.Conn
	unreliableWrites atomic.Int32
}

func (c *lossyConn) WriteUnreliable(p []byte) (int, error) {
	c.unreliableWrites.Add(1)
	return len(p), nil
}

// lossyListener hands out lossyConns.
type lossyListener struct {
	net.Listener
	last chan *lossyConn
}

func (l *lossyListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	lc := &lossyConn{Conn: c}
	l.last <- lc
	return lc, nil
}

// TestLimitListenerKeepsTheUnreliableWrite: a connection that offers
// WriteUnreliable still offers it after the limiter wraps it, and the call
// reaches the underlying connection. The limiter shipped without this
// (2026-09-02) and every quic state the relay forwarded silently rode the
// reliable stream -- see limitedLossyConn.
func TestLimitListenerKeepsTheUnreliableWrite(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	inner := &lossyListener{Listener: raw, last: make(chan *lossyConn, 1)}
	ln := LimitListener(inner, 4, nil)
	defer ln.Close()

	accepted := make(chan net.Conn, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		accepted <- c
	}()
	client, err := net.Dial("tcp", raw.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()

	var server net.Conn
	select {
	case server = <-accepted:
	case <-time.After(2 * time.Second):
		t.Fatal("connection was not accepted")
	}
	defer server.Close()

	uw, ok := server.(interface {
		WriteUnreliable(p []byte) (int, error)
	})
	if !ok {
		t.Fatalf("the limiter hid WriteUnreliable: got %T", server)
	}
	if _, err := uw.WriteUnreliable([]byte("state\n")); err != nil {
		t.Fatalf("WriteUnreliable: %v", err)
	}
	if got := (<-inner.last).unreliableWrites.Load(); got != 1 {
		t.Fatalf("the unreliable write did not reach the connection: %d calls", got)
	}

	// And a connection WITHOUT the method must not grow one: the transport
	// decides reliability by asserting for it.
	rawPlain, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	plain := LimitListener(rawPlain, 4, nil)
	defer plain.Close()
	acceptedPlain := make(chan net.Conn, 1)
	go func() {
		c, err := plain.Accept()
		if err != nil {
			return
		}
		acceptedPlain <- c
	}()
	clientPlain, err := net.Dial("tcp", rawPlain.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer clientPlain.Close()
	select {
	case c := <-acceptedPlain:
		defer c.Close()
		if _, has := c.(interface{ WriteUnreliable([]byte) (int, error) }); has {
			t.Fatalf("a plain tcp connection grew an unreliable write: %T", c)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("plain connection was not accepted")
	}
}
