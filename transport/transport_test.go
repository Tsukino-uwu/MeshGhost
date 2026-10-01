package transport

import (
	"bytes"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

func listen(t *testing.T) (net.Listener, string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln, ln.Addr().String()
}

// TestEchoToSelf: a line sent through a real TCP connection to a server that echoes it comes back byte for byte.
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

// TestMessagesBeforeOnReceiveAreNotLost sends before registering OnReceive, in the window after the read loop has
// started, and checks the backlog arrives in order.
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

	// Let the echoes land while no callback is registered.
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

// TestMultipleMessagesPreserveOrder: lines sent as one burst split back exactly, in order.
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

// TestLocalCloseDoesNotReportAnError: this side's own Close, which the read loop sees as net.ErrClosed, fires
// OnDisconnect but never OnError.
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

// TestOversizedLineWithNoDelimiterClosesConnection: a line past MaxLineBytes with no newline at all is refused during
// the read, not after it is buffered.
func TestOversizedLineWithNoDelimiterClosesConnection(t *testing.T) {
	ln, addr := listen(t)

	serverUp := make(chan struct{})
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		// FromConnWithLimits: setting MaxLineBytes after FromConn races the read loop, which may keep the default.
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

func TestIdleTimeoutClosesConnection(t *testing.T) {
	ln, addr := listen(t)

	serverUp := make(chan struct{})
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		// FromConnWithLimits for the same race as above; losing it leaves the 60s default.
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

// countingConn is a net.Conn that records every Write, so a test can count writes and not only bytes. Reads block
// until Close, so the read loop sits quietly while the test drives Send.
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

// TestSendIssuesExactlyOneWritePerMessage: payload and newline leave in one Write, or a datagram transport splits
// every line in two. Only the count catches a regression; the bytes match either way.
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

// TestSendUnreliableMatchesSendOverTCP: with no unreliable mode to drop into, the bytes and the write count are
// Send's.
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

// partialWriteConn fails its first Write halfway with a timeout error, as a net.Conn does when the write deadline
// expires with the kernel buffer full, and records whether Close was called.
type partialWriteConn struct {
	mu         sync.Mutex
	writeCalls int
	closed     bool
	closedCh   chan struct{}
	once       sync.Once
}

func newPartialWriteConn() *partialWriteConn {
	return &partialWriteConn{closedCh: make(chan struct{})}
}

type timeoutError struct{}

func (timeoutError) Error() string   { return "i/o timeout" }
func (timeoutError) Timeout() bool   { return true }
func (timeoutError) Temporary() bool { return true }

func (c *partialWriteConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return 0, net.ErrClosed
	}
	c.writeCalls++
	if c.writeCalls == 1 {
		return len(p) / 2, timeoutError{}
	}
	return len(p), nil
}

func (c *partialWriteConn) Read(p []byte) (int, error) {
	<-c.closedCh
	return 0, net.ErrClosed
}

func (c *partialWriteConn) Close() error {
	c.mu.Lock()
	c.closed = true
	c.mu.Unlock()
	c.once.Do(func() { close(c.closedCh) })
	return nil
}

func (c *partialWriteConn) wasClosed() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closed
}

func (c *partialWriteConn) LocalAddr() net.Addr                { return nil }
func (c *partialWriteConn) RemoteAddr() net.Addr               { return nil }
func (c *partialWriteConn) SetDeadline(t time.Time) error      { return nil }
func (c *partialWriteConn) SetReadDeadline(t time.Time) error  { return nil }
func (c *partialWriteConn) SetWriteDeadline(t time.Time) error { return nil }

// TestFailedWritePoisonsConnection: a partial write closes the connection, since NDJSON cannot re-frame after half a
// line, and the next Send fails instead of appending to the unterminated one.
func TestFailedWritePoisonsConnection(t *testing.T) {
	conn := newPartialWriteConn()
	c := FromConn(conn)
	defer c.Close()

	if err := c.Send([]byte(`{"seq":1}`)); err == nil {
		t.Fatal("first Send must surface the partial-write error")
	}
	if !conn.wasClosed() {
		t.Fatal("a failed write left the mis-framed connection open -- every later Send appends to a line that never ended")
	}
	if err := c.Send([]byte(`{"seq":2}`)); err == nil {
		t.Fatal("Send on a poisoned connection must fail, not silently write onto a mangled stream")
	}
}

// TestCloseGracefullyDeliversTheLastLineThenEOF: a line written just before the close reaches a peer that still has
// unread data in flight, followed by a clean EOF rather than a reset, and the server side closes on its own once the
// drain ends.
func TestCloseGracefullyDeliversTheLastLineThenEOF(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	accepted := make(chan net.Conn, 1)
	go func() {
		c, err := ln.Accept()
		if err == nil {
			accepted <- c
		}
	}()
	client, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()
	var serverRaw net.Conn
	select {
	case serverRaw = <-accepted:
	case <-time.After(2 * time.Second):
		t.Fatal("accept timed out")
	}

	// A slow callback keeps most of the client's lines unread in the server's kernel buffer at the close, the
	// condition that turns a plain Close into a reset.
	server := FromConnWithLimits(serverRaw, DefaultMaxLineBytes, 0, 0)
	server.OnReceive(func([]byte) { time.Sleep(2 * time.Millisecond) })
	closed := make(chan struct{})
	server.OnDisconnect(func(error) { close(closed) })

	line := []byte(`{"type":"state"}`)
	for i := 0; i < 200; i++ {
		if _, err := client.Write(append(append([]byte(nil), line...), '\n')); err != nil {
			t.Fatalf("client write %d: %v", i, err)
		}
	}

	if err := server.Send([]byte(`{"type":"reject"}`)); err != nil {
		t.Fatalf("server send: %v", err)
	}
	server.CloseGracefully(2 * time.Second)

	// The client must read the reject, then a clean EOF, never a reset.
	_ = client.SetReadDeadline(time.Now().Add(2 * time.Second))
	got, err := io.ReadAll(client)
	if err != nil {
		t.Fatalf("client read ended with %v, want a clean EOF; got %q so far", err, got)
	}
	if !bytes.Contains(got, []byte(`{"type":"reject"}`)) {
		t.Fatalf("the last line before the close never arrived; client read %q", got)
	}

	// And the server side lets go on its own when the drain ends.
	select {
	case <-closed:
	case <-time.After(3 * time.Second):
		t.Fatal("the draining server connection never closed after its drain deadline")
	}
}
