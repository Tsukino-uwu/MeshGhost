//go:build meshghost_devudp

package udpconn

import (
	"errors"
	"net"
	"testing"
	"time"
)

// TestCloseWriteKeepsRetransmittingWhatWasAlreadySent: after CloseWrite a Reject already written is still
// retransmitted. c.pending is where the retry loop's liveness is observable at all.
func TestCloseWriteKeepsRetransmittingWhatWasAlreadySent(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)
	sc := server.(*Conn)

	// The client goes away unannounced, as on a broken path, so nothing will ever ack what the relay writes next.
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

	if _, err := sc.Write([]byte(`{"type":"state"}`)); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("a write after CloseWrite returned %v, want net.ErrClosed", err)
	}
}

// TestCloseWriteStillReceives: after CloseWrite the drain still reads, so a rate-limited client's remaining flood is
// consumed rather than reset.
func TestCloseWriteStillReceives(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)
	sc := server.(*Conn)

	if err := sc.CloseWrite(); err != nil {
		t.Fatalf("CloseWrite: %v", err)
	}

	// On a hard close the listener drops this, no longer knowing the connection exists.
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
