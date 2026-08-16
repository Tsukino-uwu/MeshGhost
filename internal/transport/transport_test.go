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

// TestMessagesBeforeOnReceiveAreNotLost covers the registration-order race
// found 2026-08-16: FromConn/Dial start the read loop before returning, so
// every caller has a window between "connection exists" and "callback
// installed", and a message arriving in it used to be dropped silently —
// no error, no log, nothing to debug from. It was the cause of an
// intermittent failure across the whole suite (~9 of 12 `go test ./...`
// runs, a different test each time, always a timeout waiting for a message
// that had genuinely been sent). Reachable in production too: the relay
// installs its callback after FromConnWithLimits, so a fast client's Hello
// could go unanswered.
//
// This test deliberately sends first and registers second, and also checks
// the backlog arrives in order rather than merely arriving.
func TestMessagesBeforeOnReceiveAreNotLost(t *testing.T) {
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

	want := []string{"first", "second", "third"}
	for _, w := range want {
		if err := client.Send([]byte(w)); err != nil {
			t.Fatalf("send %q: %v", w, err)
		}
	}

	// Give the echoes time to land while no callback is registered — the
	// exact window that used to lose them.
	time.Sleep(200 * time.Millisecond)

	var mu sync.Mutex
	var got []string
	done := make(chan struct{})
	client.OnReceive(func(payload []byte) {
		mu.Lock()
		got = append(got, string(payload))
		n := len(got)
		mu.Unlock()
		if n == len(want) {
			close(done)
		}
	})

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		mu.Lock()
		defer mu.Unlock()
		t.Fatalf("messages sent before OnReceive was registered were lost: got %v, want %v", got, want)
	}

	mu.Lock()
	defer mu.Unlock()
	for i, w := range want {
		if got[i] != w {
			t.Fatalf("backlog message %d = %q, want %q (order not preserved)", i, got[i], w)
		}
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

// TestLocalCloseDoesNotReportAnError is the regression test for a real log
// line that looked like a bug and wasn't: on the shipped default transport
// (udp), every successful join was preceded in the relay's log by
//
//	relay: connection error: read tcp ...: use of closed network connection
//
// The relay closes the tcp connection itself once it has answered a
// query_only transport-discovery hello (internal/relay), and this read loop
// was parked in Scan() at the time, so our own Close() came back as
// net.ErrClosed and got reported through OnError as if a peer had done
// something. Reproduced against the real binaries 2026-08-16, then fixed
// here rather than in the relay, because every deliberate Close() in the
// codebase had the same problem.
//
// OnDisconnect must still fire: suppressing the error must not make a
// connection ending invisible, only stop it being called an error.
func TestLocalCloseDoesNotReportAnError(t *testing.T) {
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

	errs := make(chan error, 4)
	client.OnError(func(err error) { errs <- err })
	disconnected := make(chan error, 1)
	client.OnDisconnect(func(err error) { disconnected <- err })

	if err := client.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	select {
	case <-disconnected:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for disconnect after a local Close")
	}

	select {
	case err := <-errs:
		t.Fatalf("OnError fired for our own Close(): %v", err)
	default:
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
		// FromConnWithLimits, not FromConn plus a field assignment: FromConn
		// starts the read loop before it returns, so setting MaxLineBytes
		// afterward races readLoop's own read of it (see the field's doc
		// comment in transport.go). When readLoop won that race it kept the
		// 64KiB default, the 8192-byte write below stayed under it, no
		// disconnect ever came, and this test failed on the 2s timeout --
		// caught 2026-08-16 by running the suite with -count=10.
		FromConnWithLimits(conn, 1024, 0, 0)
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
		// FromConnWithLimits for the same reason as
		// TestOversizedLineWithNoDelimiterClosesConnection above: setting
		// IdleTimeout after FromConn races the read loop that is already
		// running, and losing that race leaves the real 60s default in
		// place, well past this test's 2s patience.
		FromConnWithLimits(conn, 0, 100*time.Millisecond, 0)
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

// countingConn is a net.Conn that records every Write it receives, so a
// test can assert on the *number* of writes rather than only the bytes that
// come out the other end. Reads block until Close, which is enough for
// FromConn's read loop to sit quietly while the test drives Send.
type countingConn struct {
	mu     sync.Mutex
	writes [][]byte
	closed chan struct{}
	once   sync.Once
}

func newCountingConn() *countingConn {
	return &countingConn{closed: make(chan struct{})}
}

func (c *countingConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cp := make([]byte, len(p))
	copy(cp, p)
	c.writes = append(c.writes, cp)
	return len(p), nil
}

func (c *countingConn) Read(p []byte) (int, error) {
	<-c.closed
	return 0, net.ErrClosed
}

func (c *countingConn) Close() error {
	c.once.Do(func() { close(c.closed) })
	return nil
}

func (c *countingConn) LocalAddr() net.Addr                { return nil }
func (c *countingConn) RemoteAddr() net.Addr               { return nil }
func (c *countingConn) SetDeadline(t time.Time) error      { return nil }
func (c *countingConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *countingConn) SetWriteDeadline(t time.Time) error { return nil }

func (c *countingConn) snapshot() [][]byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([][]byte, len(c.writes))
	copy(out, c.writes)
	return out
}

// TestSendIssuesExactlyOneWritePerMessage pins the property that makes
// NDJSON framing survive a datagram transport: payload and its terminating
// newline must leave in a *single* Write. Send used to issue two (payload,
// then "\n"), which TCP hides completely — the bytes arrive identically
// either way — but which becomes two datagrams per message over UDP or a
// QUIC datagram, splitting every line in half with no way to reassemble it
// downstream. Found while scoping selectable transports; see the transport
// ADR in agent_docs/architecture.md.
//
// This test fails against the two-Write version, which is the point: the
// bytes-level assertions below pass either way, so only the count catches a
// regression here.
func TestSendIssuesExactlyOneWritePerMessage(t *testing.T) {
	cc := newCountingConn()
	conn := FromConn(cc)
	defer conn.Close()

	for _, payload := range [][]byte{[]byte(`{"a":1}`), []byte(`{"b":2}`)} {
		if err := conn.Send(payload); err != nil {
			t.Fatalf("send: %v", err)
		}
	}

	writes := cc.snapshot()
	if len(writes) != 2 {
		t.Fatalf("got %d writes for 2 messages, want 2 (one per message); a split payload/newline write breaks datagram transports", len(writes))
	}
	for i, want := range []string{"{\"a\":1}\n", "{\"b\":2}\n"} {
		if string(writes[i]) != want {
			t.Errorf("write %d = %q, want %q", i, writes[i], want)
		}
	}
}

// TestSendUnreliableMatchesSendOverTCP confirms the opt-out is a no-op on a
// stream transport: TCP has no unreliable mode to drop into, so the bytes
// and the write count must be identical to Send. A transport that quietly
// did something different here would make the state plane behave one way on
// tcp and another on udp for no reason a caller could see.
func TestSendUnreliableMatchesSendOverTCP(t *testing.T) {
	cc := newCountingConn()
	conn := FromConn(cc)
	defer conn.Close()

	if err := conn.SendUnreliable([]byte(`{"a":1}`)); err != nil {
		t.Fatalf("send unreliable: %v", err)
	}

	writes := cc.snapshot()
	if len(writes) != 1 {
		t.Fatalf("got %d writes, want 1", len(writes))
	}
	if got, want := string(writes[0]), "{\"a\":1}\n"; got != want {
		t.Errorf("write = %q, want %q", got, want)
	}
}
