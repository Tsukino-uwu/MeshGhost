package relay

import (
	"errors"
	"net"
	"testing"
	"time"
)

// tempErr is what the kernel hands Accept when it is out of descriptors:
// a net.Error whose Temporary() is true. syscall.Errno(EMFILE) reports the
// same, which is what this stands in for without needing to exhaust anything.
type tempErr struct{}

func (tempErr) Error() string   { return "accept: too many open files" }
func (tempErr) Timeout() bool   { return false }
func (tempErr) Temporary() bool { return true }

// flakyListener returns one temporary error, then behaves like a channel of
// connections until Close.
type flakyListener struct {
	conns  chan net.Conn
	closed chan struct{}
	failed bool
}

func (l *flakyListener) Accept() (net.Conn, error) {
	if !l.failed {
		l.failed = true
		return nil, tempErr{}
	}
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}
func (l *flakyListener) Close() error   { close(l.closed); return nil }
func (l *flakyListener) Addr() net.Addr { return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)} }

// TestServeSurvivesATemporaryAcceptError pins that a temporary Accept error
// (out of file descriptors, which a stranger can arrange by holding
// connections open) is retried rather than returned. Until 2026-09-02 Serve
// returned on any error, and the relay binary treats that as fatal -- so
// descriptor exhaustion from outside was a remote crash of every room.
func TestServeSurvivesATemporaryAcceptError(t *testing.T) {
	ln := &flakyListener{conns: make(chan net.Conn, 1), closed: make(chan struct{})}
	s := NewServer()

	done := make(chan error, 1)
	go func() { done <- s.Serve(ln) }()

	// After the temporary error, a real connection must still be served:
	// the far end of the pipe sees the relay's hello timer close it, which
	// only happens if handleConn ran.
	server, client := net.Pipe()
	ln.conns <- server
	select {
	case err := <-done:
		t.Fatalf("Serve returned on a temporary Accept error: %v", err)
	case <-time.After(200 * time.Millisecond):
	}
	_ = client.Close()

	ln.Close()
	select {
	case err := <-done:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("Serve returned %v after Close, want net.ErrClosed", err)
		}
	case <-time.After(timeout):
		t.Fatal("Serve did not return after the listener closed")
	}
}
