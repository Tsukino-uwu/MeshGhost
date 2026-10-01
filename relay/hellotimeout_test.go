package relay

import (
	"net"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// backdatedListener hands out connections accepted age ago, as tlsx.servedConn and quicconn.Conn report after their
// own handshake.
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

// TestTheHelloTimeoutCountsFromAccept: time a listener already spent in its own handshake counts against the hello
// timeout.
func TestTheHelloTimeoutCountsFromAccept(t *testing.T) {
	s := NewServer()
	s.HelloTimeout = 2 * time.Second
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
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
