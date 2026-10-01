package transport

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

// TestAPeerThatStopsReadingFailsTheWriteAtTheDeadline drives a real socket whose peer accepts and never reads, so only
// the write deadline can end the Send; TestFailedWritePoisonsConnection fakes the timeout and passes with no deadline
// set. The error must be a timeout, and the connection poisoned: IsClosed true and the next Send failing.
//
// Both socket buffers are shrunk to 1 KiB first; otherwise how much must be written before the kernel stops accepting
// is large and platform-dependent (Windows loopback buffers generously), and the test is slow or flaky.
func TestAPeerThatStopsReadingFailsTheWriteAtTheDeadline(t *testing.T) {
	ln, addr := listen(t)

	accepted := make(chan net.Conn, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			close(accepted)
			return
		}
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.SetReadBuffer(1024)
		}
		// Never reads, and stays open, so only the deadline can end the write.
		accepted <- c
	}()

	raw, err := net.DialTimeout("tcp", addr, DefaultDialTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if tc, ok := raw.(*net.TCPConn); ok {
		if err := tc.SetWriteBuffer(1024); err != nil {
			t.Fatalf("set write buffer: %v", err)
		}
	}

	peer, ok := <-accepted
	if !ok {
		t.Fatal("accept failed")
	}
	t.Cleanup(func() { peer.Close() })

	// 250 ms: this tests that the deadline fires, not its shipped value.
	conn := FromConnWithLimits(raw, 0, 0, 250*time.Millisecond)
	t.Cleanup(func() { conn.Close() })

	payload := bytes.Repeat([]byte("x"), 64*1024)
	var sendErr error
	// Bounded so a kernel that absorbs everything fails clearly instead of hanging: 16 MiB is past any loopback buffer.
	for i := 0; i < 256; i++ {
		if sendErr = conn.Send(payload); sendErr != nil {
			t.Logf("the write deadline fired on send %d of at most 256 (64 KiB each)", i+1)
			break
		}
	}
	if sendErr == nil {
		t.Fatal("16 MiB was written to a peer that never reads and every Send succeeded: " +
			"the write deadline never fired")
	}

	var netErr net.Error
	if !errors.As(sendErr, &netErr) || !netErr.Timeout() {
		t.Fatalf("Send returned %v (%T), want a timeout error — anything else means the "+
			"write ended for some reason other than WriteTimeout", sendErr, sendErr)
	}

	if !conn.IsClosed() {
		t.Fatal("Send timed out and left the connection open: an expired write can stop " +
			"mid-line, and NDJSON cannot resynchronize after that (see Send's comment on " +
			"the 2026-09-01 150-peer session)")
	}
	if err := conn.Send([]byte("anything")); err == nil {
		t.Fatal("a Send after the timed-out one succeeded; the poisoned connection is " +
			"still accepting writes")
	}
}

// lineLimitPeer brings up a server whose read side is capped at maxLine and returns a client to write into it, the
// lines the server delivered, and its disconnect errors.
func lineLimitPeer(t *testing.T, maxLine int) (client *NDJSONConn, lines chan []byte, disconnected chan error) {
	t.Helper()
	ln, addr := listen(t)

	lines = make(chan []byte, 4)
	disconnected = make(chan error, 4)

	serverUp := make(chan struct{})
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			close(serverUp)
			return
		}
		// FromConnWithLimits: a limit set after FromConn races the read loop, and the default may win.
		server := FromConnWithLimits(conn, maxLine, 0, 0)
		server.OnReceive(func(payload []byte) {
			lines <- append([]byte(nil), payload...)
		})
		server.OnDisconnect(func(err error) { disconnected <- err })
		close(serverUp)
	}()

	client, err := Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { client.Close() })
	<-serverUp
	return client, lines, disconnected
}

// TestTheLargestAcceptedLineIsOneByteUnderMaxLineBytes pins the accepted boundary, which is not what the constant's
// name suggests: bufio.Scanner's buffer grows to max bytes and the delimiter must fit in it beside the payload, so the
// largest payload delivered is MaxLineBytes-1. protocol.MaxPayloadBytes is one under protocol.MaxLineBytes for this.
func TestTheLargestAcceptedLineIsOneByteUnderMaxLineBytes(t *testing.T) {
	const maxLine = 1024
	client, lines, disconnected := lineLimitPeer(t, maxLine)

	payload := bytes.Repeat([]byte("x"), maxLine-1)
	if err := client.Send(payload); err != nil {
		t.Fatalf("send: %v", err)
	}

	select {
	case got := <-lines:
		if len(got) != maxLine-1 {
			t.Fatalf("delivered %d bytes, want %d", len(got), maxLine-1)
		}
		if !bytes.Equal(got, payload) {
			t.Fatal("the delivered line is not the one that was sent")
		}
	case err := <-disconnected:
		t.Fatalf("a %d-byte line against a %d-byte limit was refused (%v); the largest "+
			"legal line must be accepted, or every bound derived from MaxLineBytes is wrong",
			maxLine-1, maxLine, err)
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for a %d-byte line against a %d-byte limit",
			maxLine-1, maxLine)
	}
}

// TestALineOfExactlyMaxLineBytesIsRefusedBecauseItsDelimiterDoesNotFit is the other side of that boundary. If it fails
// because the line was accepted, the effective cap moved by a byte and protocol.MaxPayloadBytes needs re-reading.
func TestALineOfExactlyMaxLineBytesIsRefusedBecauseItsDelimiterDoesNotFit(t *testing.T) {
	const maxLine = 1024
	client, lines, disconnected := lineLimitPeer(t, maxLine)

	if err := client.Send(bytes.Repeat([]byte("x"), maxLine)); err != nil {
		t.Fatalf("send: %v", err)
	}

	select {
	case got := <-lines:
		t.Fatalf("a %d-byte payload was DELIVERED against a %d-byte limit (%d bytes read). "+
			"The delimiter used not to fit in the scanner's buffer; if that changed, the "+
			"effective cap is now MaxLineBytes rather than MaxLineBytes-1 and the send-side "+
			"checks need re-reading", maxLine, maxLine, len(got))
	case err := <-disconnected:
		if err == nil || !strings.Contains(err.Error(), "token too long") {
			t.Fatalf("disconnected with %v, want a token-too-long error", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("a %d-byte payload against a %d-byte limit neither arrived nor closed the "+
			"connection", maxLine, maxLine)
	}
}

// TestALineOverTheLimitWithItsDelimiterEndsTheConnectionWithNoResync: a well-formed line one byte too long, the one
// case that could look skippable, still ends the connection, so a short line sent after it is never delivered. The
// relay depends on that: an oversized line means the peer reconnects.
func TestALineOverTheLimitWithItsDelimiterEndsTheConnectionWithNoResync(t *testing.T) {
	const maxLine = 1024
	client, lines, disconnected := lineLimitPeer(t, maxLine)

	if err := client.Send(bytes.Repeat([]byte("x"), maxLine+1)); err != nil {
		t.Fatalf("send oversized: %v", err)
	}

	select {
	case err := <-disconnected:
		if err == nil || !strings.Contains(err.Error(), "token too long") {
			t.Fatalf("disconnected with %v, want a token-too-long error", err)
		}
		// The error names the offending line: "token too long" alone does not say which.
		if !strings.Contains(err.Error(), "line head:") {
			t.Errorf("the oversized-line error does not carry the line head: %v", err)
		}
	case got := <-lines:
		t.Fatalf("a %d-byte payload was delivered against a %d-byte limit (%d bytes)",
			maxLine+1, maxLine, len(got))
	case <-time.After(2 * time.Second):
		t.Fatal("an oversized line with a delimiter neither closed the connection nor arrived")
	}

	// Send may not report the close on the first attempt (the kernel accepts a write before it processes the FIN or
	// RST), so the assertion is on delivery.
	_ = client.Send([]byte(fmt.Sprintf("short-%d", maxLine)))
	select {
	case got := <-lines:
		t.Fatalf("the connection resynchronized after an oversized line and delivered %q; "+
			"the read loop is meant to end the connection instead", got)
	case <-time.After(300 * time.Millisecond):
	}
}
