package transport

// Two gaps in this package's coverage, both found by the 2026-09-07 review and
// closed here on 2026-09-08.
//
//  1. **WriteTimeout had no test at all.** DefaultWriteTimeout is what the whole
//     slow-peer design turns on — relay.Room.Forward's doc comment names it as
//     the reason one stalled room member cannot freeze delivery to the rest of
//     the room — and it was implicated in the 2026-09-05 Linux-only
//     TestRateLimitedClientReceivesRejectBeforeClose failure. The nearest
//     existing test, TestFailedWritePoisonsConnection, drives a fake net.Conn
//     that returns a synthetic timeout error, so it pins Send's REACTION to a
//     failed write and never that a real deadline fires at all: delete the
//     SetWriteDeadline calls from Send and that test still passes.
//
//  2. **Line limits were tested only at the no-delimiter extreme.**
//     TestOversizedLineWithNoDelimiterClosesConnection writes 8192 bytes against
//     a 1024-byte limit with no '\n' anywhere. Nothing exercised the boundary
//     itself, so an off-by-one in either direction — refusing a legal line, or
//     accepting one byte past the cap — was invisible.

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

// TestAPeerThatStopsReadingFailsTheWriteAtTheDeadline drives a real socket
// whose peer accepts the connection and then never reads a byte, which is the
// production shape of the problem: a game or relay that is alive at the TCP
// level and stalled above it. Nothing hangs up, so there is no error to observe
// except the deadline.
//
// Both ends' socket buffers are shrunk to 1 KiB first. Without that the amount
// that has to be written before the kernel stops accepting is large and
// platform-dependent (Windows loopback in particular buffers generously), and a
// test that guesses at it is a slow test on a good day and a flake on a bad
// one. With it, the fill is a handful of 64 KiB writes.
//
// What this pins, beyond "an error comes back": the error is a TIMEOUT (so it
// is the deadline that produced it, not a hangup), and the connection is left
// POISONED — IsClosed reports true and the next Send fails. That second half is
// the 2026-09-01 150-peer lesson recorded in Send's own comment: a write that
// expires mid-line leaves NDJSON unresynchronizable, so the socket must not
// survive it. A refactor that returned the timeout while leaving the connection
// open would pass a naive "Send errors" assertion and reintroduce the exact
// stream corruption that cost that session.
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
		// Deliberately never reads. Held open so the socket stays alive and
		// only the deadline can end the write.
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

	// 250 ms rather than the shipped 10 s: this test is about whether the
	// deadline fires, not about its production value.
	conn := FromConnWithLimits(raw, 0, 0, 250*time.Millisecond)
	t.Cleanup(func() { conn.Close() })

	payload := bytes.Repeat([]byte("x"), 64*1024)
	var sendErr error
	// Bounded rather than open-ended so a kernel that absorbs everything fails
	// this test with a clear message instead of hanging: 256 * 64 KiB is 16 MiB,
	// far past any loopback buffer, and each attempt costs at most 250 ms only
	// once the buffer is actually full.
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

// lineLimitPeer brings up a server whose read side is capped at maxLine and
// returns a client to write into it, the lines the server delivered, and its
// disconnect errors. It is the shared fixture for the three boundary tests
// below.
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
		// FromConnWithLimits, not a field assignment after FromConn, for the
		// reason TestOversizedLineWithNoDelimiterClosesConnection records:
		// FromConn starts the read loop before returning, so a limit set
		// afterwards races it and the default silently wins.
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

// TestTheLargestAcceptedLineIsOneByteUnderMaxLineBytes pins the ACTUAL accepted
// boundary, which is not the one the constant's name suggests, and this test
// asserts what the code does rather than what the name implies.
//
// Measured 2026-09-08 against Go's bufio.Scanner: with Buffer(_, max), a payload
// of max-1 bytes is delivered and a payload of exactly max bytes is refused with
// ErrTooLong. The reason is structural, not an accident of this package: the
// scanner's buffer can grow to max bytes and no further, and the DELIMITER has
// to fit inside it alongside the token — a max-byte payload plus its '\n' is
// max+1 bytes, so the buffer fills with no newline in sight and the scan dies.
//
// So the effective cap on a payload is MaxLineBytes-1, and every send-side check
// in this repo that compares a marshalled line with `<= protocol.MaxLineBytes`
// is one byte optimistic. That is a live off-by-one, not a hypothetical: it is
// out of this package's hands (core/sending.go:334 and relay's welcome sizing
// both own their own check), and pinning the transport's real behaviour here is
// what makes it findable from the read side.
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

// TestALineOfExactlyMaxLineBytesIsRefusedBecauseItsDelimiterDoesNotFit is the
// other side of the boundary above, written as an assertion on the behaviour
// that actually exists rather than the one the constant's name promises.
//
// If this test ever fails because the line was ACCEPTED, that is not
// automatically a regression — it means the effective cap moved by a byte, and
// the send-side checks that compare with `<=` became correct. Read this comment
// and TestTheLargestAcceptedLineIsOneByteUnderMaxLineBytes together before
// changing either.
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

// TestALineOverTheLimitWithItsDelimiterEndsTheConnectionWithNoResync covers the
// case TestOversizedLineWithNoDelimiterClosesConnection does not: a line that is
// too long but is properly terminated. The distinction is worth a test of its
// own because the two reach ErrTooLong by different routes — the no-delimiter
// case fills the buffer while the split function is still looking for a '\n',
// this one has a perfectly well-formed line that is simply one byte too big —
// and only this one could plausibly be "skipped and resynchronized from".
//
// It is not. The assertion is what the code does, not what a reader might hope:
// the read loop closes the connection on ErrTooLong, so a well-formed short line
// sent immediately afterwards is never delivered. That is deliberate (see
// fail()'s comment: an oversized line never reaches a caller's OnReceive, so the
// loop has to terminate the connection itself) and it is what the relay depends
// on — an oversized line is a peer that has to reconnect, not one that gets
// another try on the same socket.
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
		// The error names the offending line, which is the 2026-09-01 lesson
		// recorded in readLoop: "token too long" alone says a line was
		// oversized and nothing about WHICH.
		if !strings.Contains(err.Error(), "line head:") {
			t.Errorf("the oversized-line error does not carry the line head: %v", err)
		}
	case got := <-lines:
		t.Fatalf("a %d-byte payload was delivered against a %d-byte limit (%d bytes)",
			maxLine+1, maxLine, len(got))
	case <-time.After(2 * time.Second):
		t.Fatal("an oversized line with a delimiter neither closed the connection nor arrived")
	}

	// The connection is gone, so nothing after it is delivered. Send may or may
	// not report the close on the first attempt (the local kernel accepts a
	// write into a socket whose FIN/RST has not been processed yet), so the
	// assertion is on delivery, which is unambiguous.
	_ = client.Send([]byte(fmt.Sprintf("short-%d", maxLine)))
	select {
	case got := <-lines:
		t.Fatalf("the connection resynchronized after an oversized line and delivered %q; "+
			"the read loop is meant to end the connection instead", got)
	case <-time.After(300 * time.Millisecond):
	}
}
