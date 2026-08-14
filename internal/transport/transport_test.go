package transport

import (
	"bytes"
	"net"
	"sync"
	"testing"
	"time"
)

// listen starts a TCP listener on an ephemeral port and returns it plus its
// address, closing it automatically at test end.
func listen(t *testing.T) (net.Listener, string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln, ln.Addr().String()
}

// TestEchoToSelf covers the "echo to self" milestone from CLAUDE.md's small
// runnable steps: a client sends a line through a real TCP connection to a
// server that echoes it straight back, and the client observes the same
// bytes it sent.
func TestEchoToSelf(t *testing.T) {
	ln, addr := listen(t)

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		server := FromConn(conn)
		server.OnReceive(func(payload []byte) {
			_ = server.Send(payload)
		})
	}()

	client, err := Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()

	received := make(chan []byte, 1)
	client.OnReceive(func(payload []byte) {
		received <- payload
	})

	want := []byte(`{"type":"ping","payload":{"nonce":1}}`)
	if err := client.Send(want); err != nil {
		t.Fatalf("send: %v", err)
	}

	select {
	case got := <-received:
		if string(got) != string(want) {
			t.Fatalf("echoed payload = %q, want %q", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for echo")
	}
}

// TestMultipleMessagesPreserveOrder confirms NDJSON framing splits back
// exactly the lines that were sent, in order, even when they arrive as one
// burst of writes.
func TestMultipleMessagesPreserveOrder(t *testing.T) {
	ln, addr := listen(t)

	serverUp := make(chan struct{})
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		server := FromConn(conn)
		server.OnReceive(func(payload []byte) {
			_ = server.Send(payload)
		})
		close(serverUp)
	}()

	client, err := Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()
	<-serverUp

	var mu sync.Mutex
	var got [][]byte
	done := make(chan struct{})
	client.OnReceive(func(payload []byte) {
		mu.Lock()
		got = append(got, append([]byte(nil), payload...))
		n := len(got)
		mu.Unlock()
		if n == 3 {
			close(done)
		}
	})

	want := []string{"one", "two", "three"}
	for _, w := range want {
		if err := client.Send([]byte(w)); err != nil {
			t.Fatalf("send %q: %v", w, err)
		}
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for all messages")
	}

	mu.Lock()
	defer mu.Unlock()
	for i, w := range want {
		if string(got[i]) != w {
			t.Fatalf("message %d = %q, want %q", i, got[i], w)
		}
	}
}

// TestCloseFiresDisconnect confirms closing one side of the connection is
// observed by the other side's OnDisconnect, not silently dropped.
func TestCloseFiresDisconnect(t *testing.T) {
	ln, addr := listen(t)

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		FromConn(conn)
	}()

	client, err := Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}

	disconnected := make(chan error, 1)
	client.OnDisconnect(func(err error) {
		disconnected <- err
	})

	if err := client.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	select {
	case <-disconnected:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for disconnect")
	}
}

// TestOversizedLineWithNoDelimiterClosesConnection confirms a line
// exceeding MaxLineBytes is rejected during the read itself, not after
// being fully buffered. Found while scoping relay-safety hardening
// (agent_docs/architecture.md's room-code/version ADR): the old
// bufio.Reader-based readLoop grew its internal buffer without bound until
// it found a '\n', so a peer that streamed bytes with no newline at all
// could force unbounded memory growth — a length check on the delivered
// payload (as internal/relay's MaxLineBytes check used to be) ran too late
// to prevent that. This test sends well over the limit with no trailing
// newline at all, the exact scenario the old implementation couldn't bound.
func TestOversizedLineWithNoDelimiterClosesConnection(t *testing.T) {
	ln, addr := listen(t)

	serverUp := make(chan struct{})
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		server := FromConn(conn)
		server.MaxLineBytes = 1024
		close(serverUp)
	}()

	client, err := Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()
	<-serverUp

	disconnected := make(chan error, 1)
	client.OnDisconnect(func(err error) { disconnected <- err })

	// Well over the server's 1024-byte limit, no newline anywhere in it.
	huge := bytes.Repeat([]byte("x"), 8192)
	if _, err := client.conn.Write(huge); err != nil {
		t.Fatalf("write: %v", err)
	}

	select {
	case <-disconnected:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for oversized-line-with-no-delimiter disconnect")
	}
}

// TestIdleTimeoutClosesConnection confirms a connection that never
// completes a line within IdleTimeout is closed rather than held open
// forever — agent_docs/architecture.md's room-code/version ADR.
func TestIdleTimeoutClosesConnection(t *testing.T) {
	ln, addr := listen(t)

	serverUp := make(chan struct{})
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		server := FromConn(conn)
		server.IdleTimeout = 100 * time.Millisecond
		close(serverUp)
	}()

	client, err := Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()
	<-serverUp

	// Client deliberately sends nothing.
	disconnected := make(chan struct{})
	client.OnDisconnect(func(err error) { close(disconnected) })

	select {
	case <-disconnected:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for idle-timeout disconnect")
	}
}
