package quicconn

// P1d-2 from the transports cell of the 2026-09-12 adversarial review.
//
// SetWriteDeadline stored a value that only Write read. WriteUnreliable went
// straight into quic-go's SendDatagram, whose queue holds 32 frames and whose
// own comment reads "Once that limit is reached, Add blocks until the queue
// size has reduced" -- on a select with no timeout. So a quic peer whose
// congestion window had collapsed parked the relay's writer goroutine for that
// client, and every reliable join, leave and reject queued behind it, past the
// bound relay/outbox.go is written around.
//
// These drive the real Conn over a real quic connection. The queue depth is
// quic-go's, not ours, so the test fills it by writing into a peer that never
// reads and never acknowledges rather than by reaching into internals.

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

	// Consume the byte that primed the stream, so a test reading for its own
	// datagram does not get handed the handshake's leftovers instead. The
	// listener only surfaces a connection once its stream carries something,
	// which is why the prime exists at all.
	_ = server.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := server.Read(make([]byte, 8)); err != nil {
		t.Fatalf("draining the stream prime: %v", err)
	}
	_ = server.SetReadDeadline(time.Time{})
	return server, client
}

// The bound itself: with the queue jammed, an unreliable write returns inside
// its deadline instead of parking the caller.
func TestAnUnreliableWriteHonoursItsWriteDeadline(t *testing.T) {
	_, client := dialOne(t)

	// Far more than quic-go's 32-frame queue, at a size that will not be
	// drained quickly, so at least one send is parked when the deadline runs.
	payload := make([]byte, 1000)
	if err := client.SetWriteDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
		t.Fatalf("set deadline: %v", err)
	}

	deadline := time.Now().Add(20 * time.Second)
	for i := 0; i < 2000 && time.Now().Before(deadline); i++ {
		start := time.Now()
		if _, err := client.WriteUnreliable(payload); err != nil {
			// A refusal is fine (too large for the path, connection gone); a
			// STALL is what this test is about.
			continue
		}
		// Generous against the 100ms deadline so a scheduler hiccup on a busy
		// CI box is not a failure, and still far under the multi-second park
		// the unbounded path produced.
		if took := time.Since(start); took > 3*time.Second {
			t.Fatalf("an unreliable write blocked for %v against a 100ms write deadline -- "+
				"this is the relay's writer goroutine for one client, and every reliable "+
				"join, leave and reject queued behind it", took)
		}
		_ = client.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
	}
}

// And the converse, so the drop is not simply refusing everything: on an idle
// connection with room in the queue, an unreliable write still goes out and
// still reports what it wrote.
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
	// Verbatim, with no newline appended. streamLoop frames its lines and
	// datagramLoop deliberately does not -- a datagram is one whole message by
	// construction. Asserted rather than assumed because a first draft of this
	// test expected the stream's framing here and failed on it, which is the
	// same asymmetry the transports cell filed separately (P1d-7).
	if string(buf[:got]) != string(want) {
		t.Fatalf("got %q, want %q", buf[:got], want)
	}
}
