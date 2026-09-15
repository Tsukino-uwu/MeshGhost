//go:build meshghost_devudp

package udpconn

import (
	"errors"
	"net"
	"testing"
	"time"
)

// A refused hello must survive one dropped packet (P1d-1, 2026-09-12).
//
// relay.rejectAndClose writes a Reject and then calls
// transport.CloseGracefully, whose entire reason for existing is that the last
// line written must actually arrive. It asserts for CloseWrite and hard-closes
// anything that cannot half-close -- and this transport could not, so on the
// SHIPPED DEFAULT transport that call did the opposite of its name:
//
//   - Close ends retryLoop, so the Reject went out as exactly one datagram with
//     no retransmission behind it. Lose that packet and a client with a wrong
//     room code sees silence, which is indistinguishable from a network fault,
//     so it treats a permanent refusal as transient and reconnects forever.
//   - Close also unregisters the Conn from its listener, so the drain
//     CloseGracefully asked for read nothing -- which is the mechanism the
//     relay's rate-limit path relies on to consume a flooder's remaining
//     traffic rather than reset it.
//
// These two pin the halves separately, because they fail separately.

// TestCloseWriteKeepsRetransmittingWhatWasAlreadySent is the first half. It
// reaches into c.pending, which is how the retry loop's liveness is observable
// at all -- the same window TestATransientWriteErrorDoesNotAbandonTheRetries
// uses, for the same reason.
func TestCloseWriteKeepsRetransmittingWhatWasAlreadySent(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)
	sc := server.(*Conn)

	// The client goes away without saying so, which is what a client on a
	// broken path looks like and what makes retransmission the thing that
	// matters: nothing will ever ack what the relay is about to write.
	_ = client.Close()

	if _, err := sc.Write([]byte(`{"type":"reject","reason":"bad room code"}`)); err != nil {
		t.Fatalf("write the reject: %v", err)
	}

	// Exactly what rejectAndClose does, via transport.CloseGracefully's own
	// type assertion.
	cw, ok := server.(interface{ CloseWrite() error })
	if !ok {
		t.Fatal("this Conn cannot half-close, so transport.CloseGracefully hard-closes it and " +
			"the reject above gets one un-retransmitted datagram")
	}
	if err := cw.CloseWrite(); err != nil {
		t.Fatalf("CloseWrite: %v", err)
	}

	// Two more ticks is enough to tell "still trying" from "gave up at one",
	// and does not wait out the whole retry budget.
	const want = 2
	deadline := time.Now().Add(testTimeout)
	for {
		attempts := 0
		sc.relMu.Lock()
		for _, m := range sc.pending {
			if m.attempts > attempts {
				attempts = m.attempts
			}
		}
		pending := len(sc.pending)
		sc.relMu.Unlock()
		if attempts >= want {
			break
		}
		if pending == 0 {
			t.Fatal("the reject left the pending set with nothing acking it, so it can never be " +
				"retransmitted -- one dropped packet loses the reason for the refusal")
		}
		if !time.Now().Before(deadline) {
			t.Fatalf("after CloseWrite the retry loop had made %d attempt(s), want at least %d -- "+
				"the reject is not being retransmitted", attempts, want)
		}
		time.Sleep(10 * time.Millisecond)
	}

	// And a half-close is still a close for NEW traffic, or it is not a
	// half-close at all.
	if _, err := sc.Write([]byte(`{"type":"state"}`)); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("a write after CloseWrite returned %v, want net.ErrClosed", err)
	}
}

// TestCloseWriteStillReceives is the second half: the drain reads. The relay
// half-closes and then keeps reading for a bounded window, so a rate-limited
// client's remaining flood is consumed rather than reset, and so the Reject is
// not thrown away with it.
func TestCloseWriteStillReceives(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)
	sc := server.(*Conn)

	if err := sc.CloseWrite(); err != nil {
		t.Fatalf("CloseWrite: %v", err)
	}

	// The client had not finished talking. On a hard close this datagram is
	// dropped by the listener, which no longer knows this connection exists.
	if _, err := client.Write([]byte("still-talking\n")); err != nil {
		t.Fatalf("client write after the half-close: %v", err)
	}

	if err := server.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	buf := make([]byte, 64)
	n, err := server.Read(buf)
	if err != nil {
		t.Fatalf("reading after CloseWrite failed with %v -- the drain window reads nothing, so "+
			"the rate-limit path's whole reason for half-closing is gone", err)
	}
	if got := string(buf[:n]); got != "still-talking\n" {
		t.Fatalf("read %q after the half-close, want the client's line", got)
	}
}
