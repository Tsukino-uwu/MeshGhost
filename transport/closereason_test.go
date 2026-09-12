package transport

import (
	"errors"
	"net"
	"sync"
	"testing"
	"time"
)

// Whether a disconnect is REPORTED must turn on who closed the connection, not
// on what the error calls itself (P1d-4, 2026-09-12).
//
// fail suppresses net.ErrClosed from OnError, and it is right to: every site in
// this project that hangs up on purpose already logs its own reason, and the
// 2026-08-16 case that put this rule here was a scary "use of closed network
// connection" line printed immediately before every successful join.
//
// The rule's PREMISE was a tcp fact -- "only a local Close() can produce this
// error" -- quietly applied to two transports where it is false. A datagram
// peer cannot hang up, so every terminal failure those transports can detect
// ends in a local close and arrives here as net.ErrClosed: udp retry
// exhaustion, a quic idle timeout, a quic peer tripping a line limit. All
// swallowed. Worse, quic-go's own connection errors answer
// errors.Is(err, net.ErrClosed) with true ON PURPOSE, so no amount of naming
// causes down in netx could reach OnError past a check on the identity alone.
//
// c.closed is the fact this package actually owns: set before the socket is
// closed at every deliberate site. Testing that instead is what these two pin.

// blockingConn hands its read loop one error, on demand, and never writes
// anything. errOnRead is what Read returns once released.
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

// releaseRead unblocks Read once, from either the test or Close, without the
// second caller panicking on an already-closed channel.
func (c *blockingConn) releaseRead()                       { c.once.Do(func() { close(c.release) }) }
func (c *blockingConn) LocalAddr() net.Addr                { return nil }
func (c *blockingConn) RemoteAddr() net.Addr               { return nil }
func (c *blockingConn) SetDeadline(t time.Time) error      { return nil }
func (c *blockingConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *blockingConn) SetWriteDeadline(t time.Time) error { return nil }

// quicShapedError is an error that IS a terminal failure and STILL answers to
// net.ErrClosed -- exactly the shape quic-go's *quic.ApplicationError has, whose
// own Is method returns true for net.ErrClosed so that generic code treats a
// dead connection as a closed one. Nothing in netx can talk this package out of
// that; only the flag can.
type quicShapedError struct{}

func (quicShapedError) Error() string        { return "Application error 0x7 (remote): peer went away" }
func (quicShapedError) Is(target error) bool { return target == net.ErrClosed }

// TestATerminalFailureIsReportedEvenWhenItClaimsToBeAClosedConnection is the
// defect: the read loop ends with an error nobody here initiated, and OnError
// must hear about it.
func TestATerminalFailureIsReportedEvenWhenItClaimsToBeAClosedConnection(t *testing.T) {
	raw := newBlockingConn(quicShapedError{})
	c := FromConn(raw)
	t.Cleanup(func() { c.Close() })

	reported := make(chan error, 1)
	c.OnError(func(err error) { reported <- err })
	gone := make(chan struct{})
	c.OnDisconnect(func(error) { close(gone) })

	// The PEER's failure, not ours: nothing calls c.Close, so c.closed is
	// false when the read loop wakes.
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

// TestOurOwnCloseIsStillSilent is the half that keeps the suppression worth
// having. Close() sets c.closed before touching the socket, so the read loop
// waking with net.ErrClosed a moment later is this side's own decision arriving
// back -- and must stay quiet, or every deliberate hangup in the project grows
// a second, scarier-looking line under the reason it already logged.
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
