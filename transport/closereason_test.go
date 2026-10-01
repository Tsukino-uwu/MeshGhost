package transport

import (
	"errors"
	"net"
	"sync"
	"testing"
	"time"
)

// These pin that whether a disconnect is reported turns on who closed the connection (c.closed), not on what the error
// calls itself.

// blockingConn's Read blocks until released, then returns errOnRead; it never writes anything.
type blockingConn struct {
	release   chan struct{}
	errOnRead error
	once      sync.Once
}

func newBlockingConn(err error) *blockingConn {
	return &blockingConn{release: make(chan struct{}), errOnRead: err}
}

func (c *blockingConn) Read(p []byte) (int, error) {
	<-c.release
	return 0, c.errOnRead
}
func (c *blockingConn) Write(p []byte) (int, error) { return len(p), nil }
func (c *blockingConn) Close() error                { c.releaseRead(); return nil }

// releaseRead unblocks Read once, whether the test or Close calls it first.
func (c *blockingConn) releaseRead()                       { c.once.Do(func() { close(c.release) }) }
func (c *blockingConn) LocalAddr() net.Addr                { return nil }
func (c *blockingConn) RemoteAddr() net.Addr               { return nil }
func (c *blockingConn) SetDeadline(t time.Time) error      { return nil }
func (c *blockingConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *blockingConn) SetWriteDeadline(t time.Time) error { return nil }

// quicShapedError is a terminal failure that still matches net.ErrClosed, the shape of quic-go's
// *quic.ApplicationError, whose Is returns true for it; only the closed flag tells it from a local close.
type quicShapedError struct{}

func (quicShapedError) Error() string        { return "Application error 0x7 (remote): peer went away" }
func (quicShapedError) Is(target error) bool { return target == net.ErrClosed }

// TestATerminalFailureIsReportedEvenWhenItClaimsToBeAClosedConnection: a read loop ending with an error this side did
// not cause reaches OnError.
func TestATerminalFailureIsReportedEvenWhenItClaimsToBeAClosedConnection(t *testing.T) {
	raw := newBlockingConn(quicShapedError{})
	c := FromConn(raw)
	t.Cleanup(func() { c.Close() })

	reported := make(chan error, 1)
	c.OnError(func(err error) { reported <- err })
	gone := make(chan struct{})
	c.OnDisconnect(func(error) { close(gone) })

	// The peer's failure, not ours: nothing calls c.Close, so c.closed is false when the read loop wakes.
	raw.releaseRead()

	select {
	case err := <-reported:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("this fixture is meant to report an error that claims net.ErrClosed; got %v", err)
		}
	case <-gone:
		t.Fatal("the connection was reported as an ordinary disconnect with no error at all -- " +
			"a peer that vanished is indistinguishable from one we hung up on, which is the " +
			"whole of P1d-4")
	case <-time.After(2 * time.Second):
		t.Fatal("neither callback fired")
	}
}

// TestOurOwnCloseIsStillSilent: Close sets c.closed before touching the socket, so the net.ErrClosed the read loop
// then wakes with stays out of OnError; a deliberate hangup has already logged its own reason.
func TestOurOwnCloseIsStillSilent(t *testing.T) {
	raw := newBlockingConn(net.ErrClosed)
	c := FromConn(raw)

	errs := make(chan error, 1)
	c.OnError(func(err error) { errs <- err })
	gone := make(chan struct{})
	c.OnDisconnect(func(error) { close(gone) })

	c.Close()

	select {
	case err := <-errs:
		t.Fatalf("closing our own connection reported %v to OnError", err)
	case <-gone:
	case <-time.After(2 * time.Second):
		t.Fatal("OnDisconnect never fired after Close")
	}
}
