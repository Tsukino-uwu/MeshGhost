package relay

import (
	"net"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// backdatedListener hands up connections that claim to have been accepted
// `age` ago -- the shape tlsx.servedConn and quicconn.Conn present after
// their own sniff, handshake or first-stream wait has already run.
type backdatedListener struct {
	net.Listener
	age time.Duration
}

type backdatedConn struct {
	net.Conn
	acceptedAt time.Time
}

func (c *backdatedConn) AcceptedAt() time.Time { return c.acceptedAt }

func (l *backdatedListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &backdatedConn{Conn: c, acceptedAt: time.Now().Add(-l.age)}, nil
}

// TestTheHelloTimeoutCountsFromAccept: the hello timeout is a bound on how
// long an unauthenticated connection is held from the moment it was
// ACCEPTED, so time already spent in a listener's own handshake counts
// against it. Fails without the fix: the timer then starts fresh in
// handleConn and this connection lives the whole HelloTimeout on top of
// the age the listener reported (pass-3 P1b, closed 2026-09-15).
func TestTheHelloTimeoutCountsFromAccept(t *testing.T) {
	s := NewServer()
	s.HelloTimeout = 2 * time.Second
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	// Almost the whole window is already spent by the time the relay sees it.
	go s.Serve(&backdatedListener{Listener: ln, age: s.HelloTimeout - 100*time.Millisecond})

	conn, err := transport.Dial(ln.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	disconnected := make(chan struct{})
	conn.OnDisconnect(func(err error) { close(disconnected) })

	started := time.Now()
	select {
	case <-disconnected:
	case <-time.After(s.HelloTimeout):
		t.Fatalf("still open after %s: the hello timer started from handleConn, not from accept", s.HelloTimeout)
	}
	if held := time.Since(started); held > s.HelloTimeout/2 {
		t.Fatalf("closed after %s; the listener had already spent all but 100ms of the %s window", held, s.HelloTimeout)
	}
}

// TestAConnectionWithNoAcceptTimeGetsTheWholeWindow: a listener that does
// not say when it accepted (a plain net.Listener, as every other relay
// test uses) still gets the full HelloTimeout from handleConn, so nothing
// is closed early for lack of the hint.
func TestAConnectionWithNoAcceptTimeGetsTheWholeWindow(t *testing.T) {
	s := NewServer()
	s.HelloTimeout = 300 * time.Millisecond
	addr := startServerWith(t, s)

	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	disconnected := make(chan struct{})
	conn.OnDisconnect(func(err error) { close(disconnected) })

	started := time.Now()
	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("never closed")
	}
	if held := time.Since(started); held < s.HelloTimeout/2 {
		t.Fatalf("closed after %s, before the %s window", held, s.HelloTimeout)
	}
}
