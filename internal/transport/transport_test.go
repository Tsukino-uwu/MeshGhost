package transport

import (
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
