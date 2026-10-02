package quicconn

import (
	"context"
	"crypto/tls"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
)

// dialOne brings up a listener and one connected Conn on each side.
func dialOne(t *testing.T) (server, client *Conn) {
	t.Helper()
	l, err := Listen("127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { l.Close() })

	type accepted struct {
		c   *Conn
		err error
	}
	acc := make(chan accepted, 1)
	go func() {
		c, err := l.Accept()
		if err != nil {
			acc <- accepted{nil, err}
			return
		}
		acc <- accepted{c.(*Conn), nil}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	qc, err := quic.DialAddr(ctx, l.Addr().String(),
		&tls.Config{InsecureSkipVerify: true, NextProtos: []string{alpn}},
		&quic.Config{EnableDatagrams: true})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	st, err := qc.OpenStreamSync(ctx)
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	// The listener only hands a connection over once its stream carries a byte.
	if _, err := st.Write([]byte("\n")); err != nil {
		t.Fatalf("prime stream: %v", err)
	}
	client = newConn(qc, st)
	t.Cleanup(func() { client.Close() })

	select {
	case a := <-acc:
		if a.err != nil {
			t.Fatalf("accept: %v", a.err)
		}
		server = a.c
	case <-time.After(5 * time.Second):
		t.Fatal("no connection accepted")
	}
	t.Cleanup(func() { server.Close() })

	// Consume the prime, so a test reading for its own datagram is not handed it instead.
	_ = server.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := server.Read(make([]byte, 8)); err != nil {
		t.Fatalf("draining the stream prime: %v", err)
	}
	_ = server.SetReadDeadline(time.Time{})
	return server, client
}

// TestAnUnreliableWriteHonoursItsWriteDeadline: with quic-go's datagram queue jammed by a peer that never reads, an
// unreliable write returns inside its deadline instead of parking the caller.
func TestAnUnreliableWriteHonoursItsWriteDeadline(t *testing.T) {
	_, client := dialOne(t)

	payload := make([]byte, 1000)
	if err := client.SetWriteDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}

	deadline := time.Now().Add(20 * time.Second)
	// Far more than quic-go's 32-frame queue, so at least one send is parked when the deadline runs.
	for i := 0; i < 2000 && time.Now().Before(deadline); i++ {
		start := time.Now()
		if _, err := client.WriteUnreliable(payload); err != nil {
			// A refusal is fine (too large for the path, connection gone); only a stall fails.
			continue
		}
		// Generous against the 100ms deadline, so a busy CI box's scheduler is not a failure.
		if took := time.Since(start); took > 3*time.Second {
			t.Fatalf("an unreliable write blocked for %v against a 100ms write deadline -- "+
				"this is the relay's writer goroutine for one client, and every reliable "+
				"join, leave and reject queued behind it", took)
		}
		_ = client.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
	}
}

// TestAnOrdinaryUnreliableWriteStillSends: with room in the queue an unreliable write still goes out and reports what
// it wrote, so the drop is not refusing everything.
func TestAnOrdinaryUnreliableWriteStillSends(t *testing.T) {
	server, client := dialOne(t)

	if err := client.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}
	want := []byte(`{"type":"state"}`)
	n, err := client.WriteUnreliable(want)
	if err != nil {
		t.Fatalf("write: %v", err)
	}
	if n != len(want) {
		t.Fatalf("wrote %d, want %d", n, len(want))
	}

	_ = server.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 256)
	got, err := server.Read(buf)
	if err != nil {
		t.Fatalf("read: %v -- an ordinary unreliable write did not arrive, so the drop is eating "+
			"traffic rather than only shedding it under congestion", err)
	}
	// Verbatim, with no newline appended: a datagram is one whole message, so datagramLoop does not frame it.
	if string(buf[:got]) != string(want) {
		t.Fatalf("got %q, want %q", buf[:got], want)
	}
}
