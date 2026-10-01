package main

import (
	"errors"
	"net"
	"os"
	"sync"
	"testing"
	"time"
)

// TestShutdownTellsEveryConnectedClient: closing the listeners is not enough, as quic-go's leaves accepted
// connections open. Asserted on tcp, where a test can read the EOF directly; the mechanism is transport-independent.
func TestShutdownTellsEveryConnectedClient(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ln := trackConns(raw)

	// Stand in for relay.Serve: accept until the listener closes, holding the server side open as a session would.
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

	// Wait until the accept loop has registered it, so the test asserts on shutdown rather than a race with the dial.
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

	// drain 0: there is no process to hold open here.
	if n := shutdown([]*trackingListener{ln}, 0); n != 1 {
		t.Fatalf("shutdown spoke to %d connection(s), want 1", n)
	}
	wg.Wait()

	// The client must learn now, not at its own idle timeout.
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

// TestATrackedConnectionIsForgottenWhenItCloses: in a long-lived relay, a map of every connection ever accepted would
// grow once per join.
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

// fullConn has three of the optional methods the codebase type-asserts for.
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

// TestTheTrackingWrapperHidesNothing: a wrapper embedding net.Conn as an interface hides every method net.Conn does
// not declare, and each one below is found by a type assertion that silently degrades when it fails.
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
		// transport finds the unreliable path by asking for the method, so a tcp connection must not answer.
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

// TestAServeErrorTellsEveryClientBeforeExit: a listener dying says goodbye to every client, as Ctrl+C does.
func TestAServeErrorTellsEveryClientBeforeExit(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ln := trackConns(raw)
	go func() {
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

	serveErr := make(chan error, 1)
	serveErr <- errors.New("tcp: accept: the listener died")
	stop := make(chan os.Signal, 1)
	failed, n := awaitShutdown(serveErr, stop, []*trackingListener{ln}, 0)
	if failed == nil {
		t.Fatal("a listener error was not reported back")
	}
	if n != 1 {
		t.Fatalf("shutdown spoke to %d connection(s) on the fatal path, want 1", n)
	}
	_ = client.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := client.Read(make([]byte, 1)); err == nil {
		t.Fatal("the client read a byte; it should have seen the connection end")
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatal("the client saw NOTHING after the listener died: the fatal path skipped the goodbye")
	}
}

// slowCloser is a net.Conn whose half-close takes a while, as a member with a stalled socket holds a FIN.
type slowCloser struct {
	net.Conn
	hold time.Duration
}

func (s *slowCloser) CloseWrite() error { time.Sleep(s.hold); return nil }

// TestShutdownHalfClosesClientsInParallel: one stalled member must not hold everyone else's goodbye for its whole
// write timeout.
func TestShutdownHalfClosesClientsInParallel(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer raw.Close()
	ln := trackConns(raw)
	const members, hold = 4, 300 * time.Millisecond
	for i := 0; i < members; i++ {
		a, b := net.Pipe()
		defer a.Close()
		defer b.Close()
		ln.mu.Lock()
		ln.conns[&slowCloser{Conn: b, hold: hold}] = struct{}{}
		ln.mu.Unlock()
	}
	started := time.Now()
	if n := ln.closeClients(); n != members {
		t.Fatalf("closeClients spoke to %d, want %d", n, members)
	}
	if took := time.Since(started); took >= time.Duration(members)*hold {
		t.Fatalf("closing %d members took %s: serial (%s each), not parallel", members, took, hold)
	}
}
