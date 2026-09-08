package main

// Two startup/shutdown rules this binary owns, both found by the 2026-09-07
// adversarial review and fixed 2026-09-08:
//
//   - where the plain udp transport lands when quic takes the shared port. The
//     PORT relocates and the bind interface does not, which is the shape
//     resolveQuicAddr next door has always had.
//   - what Ctrl+C does. Until 2026-09-08: nothing at all.

import (
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
)

// TestUDPRelocationKeepsTheBindInterface is the F7 regression.
//
// Returning FallbackUDPAddr wholesale threw away the operator's -addr along
// with its port: a relay started with `-addr 0.0.0.0:7777 -transport
// tcp,udp,quic` bound udp on 127.0.0.1, reachable from nowhere but the host's
// own machine, while the startup banner told the host to forward 7780 and the
// relay advertised udp:7780 to remote clients -- who resolve an offered port
// against the address they dialled, and so dialled a port with nothing on it.
// Every line of commentary on that constant justified the PORT; none of them
// ever addressed the host.
func TestUDPRelocationKeepsTheBindInterface(t *testing.T) {
	both := []netx.Kind{netx.TCP, netx.UDP, netx.QUIC}

	cases := []struct {
		name string
		addr string
		want string
	}{
		{"every interface", "0.0.0.0:7777", "0.0.0.0:" + FallbackUDPPort},
		{"one public interface", "203.0.113.9:7777", "203.0.113.9:" + FallbackUDPPort},
		{"ipv6", "[::]:7777", "[::]:" + FallbackUDPPort},
		{"loopback, the default", "127.0.0.1:7777", FallbackUDPAddr},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolveUDPAddr(both, tc.addr, sharesAddrPort)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("udp landed on %q for -addr %q, want %q -- only the PORT moves; a udp "+
					"listener on an interface the operator never chose is unreachable from "+
					"outside, and the relay advertises it to remote clients anyway",
					got, tc.addr, tc.want)
			}
		})
	}

	t.Run("an addr with no port keeps the old constant", func(t *testing.T) {
		// Not a shape this binary can bind either way -- netx.ListenWithTLS gets
		// the same string and refuses with its own message -- so this is about
		// not inventing a second error path for input already being refused.
		got, err := resolveUDPAddr(both, "not-an-address", sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != FallbackUDPAddr {
			t.Fatalf("got %q, want %q", got, FallbackUDPAddr)
		}
	})

	t.Run("quic still keeps the shared port", func(t *testing.T) {
		// The 2026-08-27 rule this fix must not disturb: quic is the default
		// transport, so quic keeps -addr's number and udp is the one that moves.
		got, err := resolveQuicAddr(both, "0.0.0.0:7777", sharesAddrPort)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != "0.0.0.0:7777" {
			t.Fatalf("quic landed on %q, want it on -addr's own port", got)
		}
	})
}

// TestShutdownTellsEveryConnectedClient is the F8 regression.
//
// Before 2026-09-08 this binary had no os/signal import and main() ended only
// via log.Fatalf, so an interrupt took the process down without a word. Closing
// the listeners is not enough on its own and that is the whole point of the
// tracking: quic-go's Listener.Close leaves already-accepted connections
// untouched, and quic is the shipped default, so on the transport almost every
// real session uses a host pressing Ctrl+C left every player waiting out a ~17s
// idle timeout with their ghosts gone at 3s.
//
// Asserted on tcp because a test can hold both ends of one and read the EOF
// directly; the mechanism under test (close the listeners, then close what they
// handed out) is transport-independent by construction.
func TestShutdownTellsEveryConnectedClient(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ln := trackConns(raw)

	// Stand in for relay.Serve: accept until the listener closes, and hold the
	// server side open exactly as a real session would.
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			if _, err := ln.Accept(); err != nil {
				return
			}
		}
	}()

	client, err := net.Dial("tcp", raw.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()

	// Wait until the accept loop has actually registered it, so the test is
	// asserting on shutdown rather than on a race with the dial.
	deadline := time.Now().Add(2 * time.Second)
	for {
		ln.mu.Lock()
		n := len(ln.conns)
		ln.mu.Unlock()
		if n == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the accepted connection was never tracked")
		}
		time.Sleep(time.Millisecond)
	}

	// drain 0: the drain only holds the process open long enough for a quic
	// CONNECTION_CLOSE to leave, and there is no process to hold here.
	if n := shutdown([]*trackingListener{ln}, 0); n != 1 {
		t.Fatalf("shutdown spoke to %d connection(s), want 1", n)
	}
	wg.Wait()

	// The client must learn NOW, not when its own idle timeout expires.
	if err := client.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	buf := make([]byte, 1)
	if _, err := client.Read(buf); err == nil {
		t.Fatal("the client read a byte; it should have seen the connection end")
	} else if errors.Is(err, net.ErrClosed) {
		t.Fatalf("read: %v", err)
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("the client saw NOTHING and timed out: this is the defect -- on a real session " +
			"it would sit on a dead relay until its own idle timeout, with its ghosts aged out " +
			"long before")
	}

	// And nothing is accepted after the listeners are closed.
	if c, err := net.DialTimeout("tcp", raw.Addr().String(), 500*time.Millisecond); err == nil {
		c.Close()
		t.Fatal("the relay still accepted a connection after shutdown")
	}
}

// TestATrackedConnectionIsForgottenWhenItCloses keeps the tracking from becoming
// a leak: a relay runs for weeks and a map keyed by every connection it ever
// accepted would grow for all of them.
func TestATrackedConnectionIsForgottenWhenItCloses(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer raw.Close()
	ln := trackConns(raw)

	client, err := net.Dial("tcp", raw.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()
	served, err := ln.Accept()
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	if err := served.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	ln.mu.Lock()
	n := len(ln.conns)
	ln.mu.Unlock()
	if n != 0 {
		t.Fatalf("%d connection(s) still tracked after the connection closed", n)
	}
	if got := ln.closeClients(); got != 0 {
		t.Fatalf("closeClients found %d connection(s) to close, want 0", got)
	}
}

// fakeConn is a net.Conn with nothing optional on it.
type fakeConn struct{ net.Conn }

// fullConn has all three of the optional methods this codebase type-asserts for.
type fullConn struct {
	net.Conn
	closedWrite bool
}

func (c *fullConn) CloseWrite() error                     { c.closedWrite = true; return nil }
func (c *fullConn) TransportName() string                 { return "quic" }
func (c *fullConn) WriteUnreliable(p []byte) (int, error) { return len(p), nil }

// oneConnListener hands out c once, then blocks forever on Accept.
type oneConnListener struct {
	net.Listener
	c    net.Conn
	once sync.Once
}

func (l *oneConnListener) Accept() (net.Conn, error) {
	var out net.Conn
	l.once.Do(func() { out = l.c })
	if out == nil {
		return nil, net.ErrClosed
	}
	return out, nil
}
func (l *oneConnListener) Close() error   { return nil }
func (l *oneConnListener) Addr() net.Addr { return nil }

// TestTheTrackingWrapperHidesNothing is the fourth instance of a wrapper bug
// this repo has now had (2026-09-05, 2026-09-06, 2026-09-07, all in
// netx/limit.go's story), written as a test instead: a wrapper embedding
// net.Conn as an INTERFACE hides every method net.Conn does not declare, and
// each of the three below is found by a type assertion somewhere that silently
// degrades when it fails -- a reject lost to a RESET, every client logged as
// "tcp", every quic state forced onto the ordered stream.
func TestTheTrackingWrapperHidesNothing(t *testing.T) {
	t.Run("a lossy connection keeps all three", func(t *testing.T) {
		underlying := &fullConn{}
		ln := trackConns(&oneConnListener{c: underlying})
		got, err := ln.Accept()
		if err != nil {
			t.Fatalf("accept: %v", err)
		}
		if _, ok := got.(unreliableWriter); !ok {
			t.Fatal("WriteUnreliable is hidden: every state on this connection would ride the " +
				"ordered stream, which is the 2026-09-02 incident")
		}
		tn, ok := got.(interface{ TransportName() string })
		if !ok || tn.TransportName() != "quic" {
			t.Fatal("TransportName is hidden: every client would be logged as tcp")
		}
		cw, ok := got.(interface{ CloseWrite() error })
		if !ok {
			t.Fatal("CloseWrite is hidden: transport.CloseGracefully degrades to a RESET, and the " +
				"reject the relay just wrote is lost")
		}
		if err := cw.CloseWrite(); err != nil || !underlying.closedWrite {
			t.Fatalf("CloseWrite did not reach the underlying connection (err=%v)", err)
		}
	})

	t.Run("a plain connection gains no datagram plane", func(t *testing.T) {
		// The other direction, and it matters just as much: transport decides
		// whether the unreliable path exists by asking whether the method is
		// there, so a wrapper that always answers yes makes a tcp connection
		// claim a datagram plane it has not got.
		ln := trackConns(&oneConnListener{c: &fakeConn{}})
		got, err := ln.Accept()
		if err != nil {
			t.Fatalf("accept: %v", err)
		}
		if _, ok := got.(unreliableWriter); ok {
			t.Fatal("a plain connection answered the WriteUnreliable assertion")
		}
	})
}
